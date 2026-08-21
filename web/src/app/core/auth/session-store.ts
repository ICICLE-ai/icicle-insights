import { HttpClient } from '@angular/common/http';
import { Service, computed, effect, inject, signal } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { firstValueFrom, timer } from 'rxjs';

import { INSIGHTS_CONFIG } from '../config';
import { TokenStore } from './token-store';

/**
 * What the server makes of whoever is holding the current credential.
 *
 * `unknown` is the state before the probe resolves, distinct from `anonymous`: showing "Public"
 * while a token is still being checked would flicker to "admin" a moment later.
 */
export type SessionStatus = 'unknown' | 'anonymous' | 'authenticated' | 'admin';

/** Claim names read from a Tapis token for display-only identity and expiry UX. */
interface TapisClaims {
  'tapis/username'?: unknown;
  'tapis/tenant_id'?: unknown;
  exp?: unknown;
}

/**
 * Resolves whether the current credential is an admin, and who it belongs to.
 *
 * **There is no `/me` endpoint**, by design — see `docs/frontend.md`. Admin status is discovered
 * by attempting an admin-only read and reading the status: 200 means admin, 403 means
 * authenticated but not permitted, 401 means no usable credential. Those three call for
 * genuinely different words on screen, so they are kept apart rather than collapsed into a
 * boolean.
 *
 * The probe re-runs whenever the held token changes, including when it first arrives from the
 * cookie or a parent frame after startup.
 */
@Service()
export class SessionStore {
  private readonly http = inject(HttpClient);
  private readonly config = inject(INSIGHTS_CONFIG);
  private readonly tokens = inject(TokenStore);

  private readonly statusState = signal<SessionStatus>('unknown');
  private probeSequence = 0;
  private readonly minute = toSignal(timer(0, 60_000), { initialValue: 0 });

  readonly status = this.statusState.asReadonly();

  /** True only when the server confirmed it. Never derived from the token's own contents. */
  readonly isAdmin = computed(() => this.statusState() === 'admin');

  /**
   * The username to show in the header, read from the token's `tapis/username` claim.
   *
   * **Display only.** Anyone can forge a claim in an unverified token, so this decides what is
   * printed and never what is permitted — `isAdmin` comes from the server's answer, not from
   * here. The server verifies the same token's signature against the tenant key before honouring
   * anything.
   */
  readonly username = computed(() => {
    const token = this.tokens.token();
    const username = token ? readClaims(token)?.['tapis/username'] : null;
    return typeof username === 'string' && username.trim() ? username.trim() : null;
  });

  /**
   * Display-only expiry from the unverified JWT payload. The server still decides whether the
   * credential works; this exists solely to warn a person before an editing session lapses.
   */
  readonly expiresAt = computed(() => {
    const token = this.tokens.token();
    const exp = token ? readClaims(token)?.exp : null;
    if (typeof exp !== 'number' || !Number.isFinite(exp)) {
      return null;
    }
    return new Date(exp * 1_000);
  });

  readonly isExpired = computed(() => {
    this.minute();
    const expiry = this.expiresAt()?.getTime();
    return expiry !== undefined && expiry <= Date.now();
  });

  readonly expiresSoon = computed(() => {
    this.minute();
    const expiry = this.expiresAt()?.getTime();
    return expiry !== undefined && expiry > Date.now() && expiry <= Date.now() + 15 * 60 * 1_000;
  });

  constructor() {
    effect(() => {
      // Tracked so the probe re-runs when a token arrives, changes, or is cleared.
      const token = this.tokens.token();
      const sequence = ++this.probeSequence;

      if (!token) {
        this.statusState.set('anonymous');
        return;
      }

      this.statusState.set('unknown');
      void this.resolveProbe(sequence);
    });
  }

  /** Re-checks admin status, e.g. after an admin grants or revokes access. */
  async probe(): Promise<void> {
    const sequence = ++this.probeSequence;
    if (!this.tokens.token()) {
      this.statusState.set('anonymous');
      return;
    }

    this.statusState.set('unknown');
    await this.resolveProbe(sequence);
  }

  private async resolveProbe(sequence: number): Promise<void> {
    try {
      await firstValueFrom(this.http.get(`${this.config.apiBase}/admins`));
      if (sequence === this.probeSequence) {
        this.statusState.set('admin');
      }
    } catch (error) {
      const status = (error as { status?: number }).status;
      // 403 is the interesting one: a real, verified identity that simply is not an admin. It
      // must not be reported as signed-out, or the UI invites a sign-in that would change
      // nothing.
      if (sequence === this.probeSequence) {
        this.statusState.set(status === 403 ? 'authenticated' : 'anonymous');
      }
    }
  }
}

/**
 * Reads display-only claims out of a JWT without verifying it.
 *
 * Verification is impossible here — it needs the tenant's public key, which lives on the server
 * — and unnecessary, because these values only drive labels and an expiry warning. Every failure returns null so a
 * malformed or non-JWT bearer value degrades to showing no name rather than throwing during
 * render.
 */
function readClaims(token: string): TapisClaims | null {
  const segments = token.split('.');
  if (segments.length !== 3) {
    return null;
  }

  try {
    // JWT payloads are base64url: restore the standard alphabet and the padding atob expects.
    const base64 = segments[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
    const claims: unknown = JSON.parse(atob(padded));
    return typeof claims === 'object' && claims !== null ? (claims as TapisClaims) : null;
  } catch {
    return null;
  }
}
