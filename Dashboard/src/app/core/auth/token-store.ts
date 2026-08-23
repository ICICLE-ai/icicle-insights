import { DOCUMENT, Service, computed, inject, signal } from '@angular/core';

import { INSIGHTS_CONFIG } from '../config';

/** Which leg of the acquisition chain supplied the token currently held. */
export type TokenSource = 'none' | 'cookie' | 'message' | 'manual';

/**
 * Holds the Tapis token for the lifetime of the tab, and nothing longer.
 *
 * **Memory only — never `localStorage` or `sessionStorage`.** Stored credentials survive the tab
 * and are readable by any script that achieves XSS; this one dies with the page, so the blast
 * radius of a script injection is the current session rather than a durable credential.
 *
 * The token is acquired from up to three sources, in descending order of trustworthiness:
 *
 * 1. `postMessage` from an allowlisted parent origin — the only leg that works when the pod and
 *    the embedding application do not share a registrable domain.
 * 2. The `X-Tapis-Token` cookie the Pods auth callback writes.
 * 3. A value pasted by hand, for development and for recovering from the other two.
 *
 * Nothing here decides what the token *permits*. The server is the only authority on that; this
 * class knows only whether it is holding one.
 */
@Service()
export class TokenStore {
  private readonly config = inject(INSIGHTS_CONFIG);
  private readonly document = inject(DOCUMENT);

  private readonly state = signal<{ token: string | null; source: TokenSource }>({
    token: null,
    source: 'none',
  });

  /** The bearer value, or null when no credential has been acquired. */
  readonly token = computed(() => this.state().token);

  /** Where the current token came from. Surfaced in the admin UI for diagnosis. */
  readonly source = computed(() => this.state().source);

  /** Whether a credential is held. Says nothing about whether it is valid or admin. */
  readonly hasToken = computed(() => this.state().token !== null);

  /**
   * Runs the acquisition chain once and starts listening for later messages.
   *
   * Safe to call more than once; the message listener is registered a single time. Listening
   * continues after a token is found so the parent can push a refreshed one when the old
   * expires — otherwise a long-lived embed would hold a dead credential until reload.
   */
  initialize(): void {
    this.listenForParentMessages();

    const fromCookie = this.readCookie();
    if (fromCookie) {
      this.state.set({ token: fromCookie, source: 'cookie' });
    }
  }

  /** Records a token pasted by hand. Empty input clears rather than storing a blank. */
  setManualToken(token: string): void {
    const trimmed = token.trim();
    this.state.set(
      trimmed ? { token: trimmed, source: 'manual' } : { token: null, source: 'none' },
    );
  }

  /** Discards the held token. The credential itself is not revoked — only forgotten here. */
  clear(): void {
    this.state.set({ token: null, source: 'none' });
  }

  /**
   * Reads the token cookie.
   *
   * Returns null rather than throwing for every failure mode — no cookie, `HttpOnly` so script
   * cannot see it, a partitioned frame that denies access outright. All three are ordinary in
   * the embedded case and none of them is an error worth propagating; the chain simply moves on.
   */
  private readCookie(): string | null {
    let raw: string;
    try {
      raw = this.document.cookie;
    } catch {
      return null;
    }

    if (!raw) {
      return null;
    }

    const prefix = `${this.config.tokenCookieName}=`;
    for (const entry of raw.split(';')) {
      const trimmed = entry.trim();
      if (!trimmed.startsWith(prefix)) {
        continue;
      }

      const value = trimmed.slice(prefix.length);
      // Cookie values are percent-encoded when they contain anything outside the cookie-octet
      // set. A JWT is base64url and needs no encoding, but decoding is harmless when nothing
      // was encoded and necessary if the writer encoded anyway.
      try {
        return decodeURIComponent(value) || null;
      } catch {
        return value || null;
      }
    }

    return null;
  }

  private listening = false;

  /**
   * Accepts a token pushed down by an allowlisted parent frame.
   *
   * `event.origin` is checked against the allowlist **before** the payload is touched. This is
   * the entire security boundary of the mechanism: any page on the internet can frame this one
   * and post to it, so skipping the check would accept a token — and therefore an identity —
   * from an attacker. An empty allowlist accepts nothing.
   */
  private listenForParentMessages(): void {
    if (this.listening) {
      return;
    }
    this.listening = true;

    const view = this.document.defaultView;
    if (!view) {
      return;
    }

    view.addEventListener('message', (event: MessageEvent) => {
      if (!this.config.trustedParentOrigins.includes(event.origin)) {
        return;
      }

      const data: unknown = event.data;
      if (typeof data !== 'object' || data === null) {
        return;
      }

      const token = (data as { tapisToken?: unknown }).tapisToken;
      if (typeof token !== 'string' || !token.trim()) {
        return;
      }

      this.state.set({ token: token.trim(), source: 'message' });
    });
  }
}
