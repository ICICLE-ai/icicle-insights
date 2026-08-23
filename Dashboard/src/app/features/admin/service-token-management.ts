import { DOCUMENT } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { toApiError, type ApiError } from '../../core/api/api-error';
import type { MintedServiceToken, ServiceToken } from '../../core/api/models';
import { ErrorNotice } from '../../shared/ui/error-notice';
import { AdminApi } from './admin-api';
import { formatAdminDate } from './admin-format';
import { AdminStore } from './admin-store';
import { groupResourcesByPlatform } from './option-groups';

interface TokenDraft {
  readonly resourceID: string;
  readonly label: string;
  readonly expiresInDays: string;
}

/** Mints narrow resource-scoped tokens and preserves revoked rows as an audit trail. */
@Component({
  selector: 'app-service-token-management',
  imports: [DialogModule, ErrorNotice, InputTextModule],
  template: `
    <section class="ins-admin-page" aria-labelledby="service-tokens-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Deployment credentials</p>
          <h2 id="service-tokens-title">Service tokens</h2>
          <p>
            Issue expiring write access to one service resource at a time; revoked rows remain
            visible.
          </p>
        </div>
        <div class="ins-admin-table__actions">
          <button
            type="button"
            class="ins-admin-action is-secondary"
            (click)="confirmRotateKey($event)"
          >
            Rotate signing key
          </button>
          <button
            type="button"
            class="ins-admin-action"
            [disabled]="store.isLoading() || serviceResources().length === 0"
            [attr.aria-describedby]="
              !store.isLoading() && !store.error() && serviceResources().length === 0
                ? 'no-service-resources'
                : null
            "
            (click)="openMint()"
          >
            <span aria-hidden="true">＋</span> Mint token
          </button>
        </div>
      </header>

      @if (!store.isLoading() && !store.error() && serviceResources().length === 0) {
        <div id="no-service-resources" class="ins-admin-empty">
          <p>
            No service resources are registered. Create a resource with the type
            <strong>Service</strong> before minting a deployment token.
          </p>
        </div>
      }

      @if (store.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="store.reload()" />
      } @else if (store.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading service-token metadata…</div>
      } @else if (store.snapshot().serviceTokens.length === 0) {
        <div class="ins-admin-empty">
          <p>No service tokens have been issued. Mint one for a deployed resource reporter.</p>
        </div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Issued service-token metadata. Token values are shown only at creation.
            </caption>
            <thead>
              <tr>
                <th scope="col">Deployment</th>
                <th scope="col">Resource</th>
                <th scope="col">Status</th>
                <th scope="col">Expires</th>
                <th scope="col">Issued</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (token of store.snapshot().serviceTokens; track token.id ?? token.jti) {
                <tr>
                  <th scope="row" class="ins-mono">{{ token.label || 'Unlabelled deployment' }}</th>
                  <td class="ins-mono">{{ resourceName(token.resourceID) }}</td>
                  <td>
                    <span
                      class="ins-admin-status"
                      [class.is-muted]="tokenState(token).tone === 'muted'"
                      [class.is-warning]="tokenState(token).tone === 'warning'"
                      [class.is-critical]="tokenState(token).tone === 'critical'"
                    >
                      {{ tokenState(token).label }}
                    </span>
                  </td>
                  <td>{{ formatDate(token.expiresAt) }}</td>
                  <td>{{ formatDate(token.createdAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!token.id || Boolean(token.revokedAt)"
                        (click)="confirmRevoke($event, token)"
                      >
                        {{ token.revokedAt ? 'Revoked' : 'Revoke' }}
                      </button>
                    </div>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      }
    </section>

    <p-dialog
      header="Mint service token"
      closeAriaLabel="Close service token editor"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="minted() === null"
      [closable]="minted() === null"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="mintOpen()"
      (visibleChange)="setMintVisibility($event)"
      (onHide)="clearMintedToken()"
    >
      @if (minted(); as result) {
        <div class="ins-admin-once">
          <p class="ins-admin-secret-notice" role="alert">
            <strong>Copy this token now.</strong> It is returned only once and cannot be recovered.
            If it is lost, revoke this record and mint another.
          </p>

          <div class="ins-admin-form__field">
            <span id="minted-token-label">Token</span>
            <div class="ins-admin-once__value">
              <textarea
                aria-labelledby="minted-token-label"
                readonly
                spellcheck="false"
                [value]="result.token"
              ></textarea>
              <button type="button" class="ins-admin-action is-secondary" (click)="copyToken()">
                Copy
              </button>
            </div>
          </div>

          <div class="ins-admin-form__field">
            <span>Metrics endpoint</span>
            <code class="ins-mono">{{ result.endpoint }}</code>
          </div>

          <div class="ins-admin-form__actions">
            <button type="button" class="ins-admin-action" (click)="finishMint()">
              I have saved the token
            </button>
          </div>
        </div>
      } @else {
        <form class="ins-admin-form" (submit)="mintToken($event)">
          <p class="ins-admin-secret-notice">
            The credential can post metrics only for the selected service resource and expires
            automatically. Its value will be displayed once after creation.
          </p>

          <div class="ins-admin-form__field">
            <label for="token-resource">Resource</label>
            <select
              id="token-resource"
              [value]="draft().resourceID"
              (change)="updateDraft('resourceID', $event)"
            >
              @for (group of serviceResourcesByPlatform(); track group.label) {
                <optgroup [label]="group.label">
                  @for (option of group.options; track option.item.id) {
                    <option [value]="option.item.id">{{ option.label }}</option>
                  }
                </optgroup>
              }
            </select>
            <p class="ins-admin-form__hint">
              Grouped by registry scope. Only service resources appear — a token names exactly one.
            </p>
          </div>

          <div class="ins-admin-form__field">
            <label for="token-label">Deployment label</label>
            <input
              id="token-label"
              pInputText
              type="text"
              autocomplete="off"
              placeholder="prod-inference"
              [value]="draft().label"
              (input)="updateDraft('label', $event)"
            />
          </div>

          <div class="ins-admin-form__field">
            <label for="token-lifetime">Lifetime in days</label>
            <input
              id="token-lifetime"
              pInputText
              type="number"
              min="1"
              max="365"
              inputmode="numeric"
              [value]="draft().expiresInDays"
              (input)="updateDraft('expiresInDays', $event)"
            />
            <p class="ins-admin-form__hint">Allowed range: 1–365 days.</p>
          </div>

          @if (formError(); as failure) {
            <p class="ins-admin-form-error" role="alert">
              {{ failure.detail || failure.message }}
              @if (failure.requestID) {
                Request ID <code>{{ failure.requestID }}</code
                >.
              }
            </p>
          }

          <div class="ins-admin-form__actions">
            <button type="button" class="ins-admin-action is-secondary" (click)="closeMint()">
              Cancel
            </button>
            <button type="submit" class="ins-admin-action" [disabled]="!canMint() || saving()">
              {{ saving() ? 'Minting…' : 'Mint token' }}
            </button>
          </div>
        </form>
      }
    </p-dialog>
  `,
  styleUrl: './admin-records.css',
})
export class ServiceTokenManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);
  private readonly document = inject(DOCUMENT);

  protected readonly dialogStyle = { width: '36rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly mintOpen = signal(false);
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly minted = signal<MintedServiceToken | null>(null);
  protected readonly draft = signal<TokenDraft>(emptyTokenDraft());
  protected readonly formatDate = formatAdminDate;
  protected readonly Boolean = Boolean;

  protected readonly serviceResources = computed(() =>
    this.store
      .snapshot()
      .resources.filter((resource) => resource.type === 'service')
      .sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly serviceResourcesByPlatform = computed(() =>
    groupResourcesByPlatform(this.serviceResources(), this.store.snapshot().accounts),
  );

  protected readonly canMint = computed(() => {
    const draft = this.draft();
    const days = Number(draft.expiresInDays);
    return (
      draft.resourceID.length > 0 &&
      this.serviceResources().some((resource) => resource.id === draft.resourceID) &&
      draft.label.trim().length > 0 &&
      Number.isInteger(days) &&
      days >= 1 &&
      days <= 365
    );
  });

  protected openMint(): void {
    const resourceID = this.serviceResources().find((resource) => resource.id)?.id ?? '';
    this.draft.set({ ...emptyTokenDraft(), resourceID });
    this.formError.set(null);
    this.minted.set(null);
    this.mintOpen.set(true);
  }

  protected closeMint(): void {
    this.mintOpen.set(false);
    this.clearMintedToken();
  }

  protected setMintVisibility(visible: boolean): void {
    if (!visible && this.minted()) {
      return;
    }
    this.mintOpen.set(visible);
  }

  protected clearMintedToken(): void {
    this.minted.set(null);
    this.formError.set(null);
  }

  protected finishMint(): void {
    this.clearMintedToken();
    this.mintOpen.set(false);
  }

  protected updateDraft(field: keyof TokenDraft, event: Event): void {
    const value = (event.target as HTMLInputElement | HTMLSelectElement).value;
    this.draft.update((draft) => ({ ...draft, [field]: value }));
  }

  protected async mintToken(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!this.canMint() || this.saving()) {
      return;
    }

    const draft = this.draft();
    this.saving.set(true);
    this.formError.set(null);
    try {
      const minted = await this.api.mintServiceToken({
        resourceID: draft.resourceID,
        label: draft.label.trim(),
        expiresInDays: Number(draft.expiresInDays),
      });
      this.draft.set(emptyTokenDraft());
      this.minted.set(minted);
      this.store.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected async copyToken(): Promise<void> {
    const token = this.minted()?.token;
    const clipboard = this.document.defaultView?.navigator.clipboard;
    if (!token || !clipboard) {
      this.messages.add({
        severity: 'warn',
        summary: 'Copy unavailable',
        detail: 'Select the token text and copy it manually.',
        life: 4000,
      });
      return;
    }

    try {
      await clipboard.writeText(token);
      this.messages.add({
        severity: 'success',
        summary: 'Token copied',
        detail: 'Store it in the deployment secret manager now.',
        life: 3000,
      });
    } catch {
      this.messages.add({
        severity: 'warn',
        summary: 'Copy unavailable',
        detail: 'Select the token text and copy it manually.',
        life: 4000,
      });
    }
  }

  protected confirmRevoke(event: Event, token: ServiceToken): void {
    if (!token.id || token.revokedAt) {
      return;
    }

    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Revoke service token?',
      message: `${token.label ?? 'This deployment'} will immediately lose permission to post metrics. The audit row will remain.`,
      rejectLabel: 'Keep active',
      acceptLabel: 'Revoke token',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.revokeToken(token),
    });
  }

  protected confirmRotateKey(event: Event): void {
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Rotate the signing key?',
      message:
        'New tokens will use a new signing key. Existing tokens keep working until they expire.',
      rejectLabel: 'Cancel',
      acceptLabel: 'Rotate key',
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.rotateKey(),
    });
  }

  protected resourceName(resourceID: string | undefined): string {
    const resource = this.store.snapshot().resources.find((entry) => entry.id === resourceID);
    return resource?.name ?? resourceID ?? 'Unknown resource';
  }

  protected tokenState(token: ServiceToken): {
    readonly label: string;
    readonly tone: 'good' | 'warning' | 'critical' | 'muted';
  } {
    if (token.revokedAt) {
      return { label: 'Revoked', tone: 'muted' };
    }

    const expiry = Date.parse(token.expiresAt ?? '');
    if (!Number.isFinite(expiry) || expiry <= Date.now()) {
      return { label: 'Expired', tone: 'critical' };
    }
    if (expiry <= Date.now() + 30 * 24 * 60 * 60 * 1_000) {
      return { label: 'Expiring', tone: 'warning' };
    }
    return { label: 'Active', tone: 'good' };
  }

  private async revokeToken(token: ServiceToken): Promise<void> {
    if (!token.id) {
      return;
    }

    try {
      await this.api.revokeServiceToken(token.id);
      this.messages.add({
        severity: 'success',
        summary: 'Token revoked',
        detail: `${token.label ?? 'Service token'} can no longer post metrics.`,
        life: 3500,
      });
      this.store.reload();
    } catch (error) {
      this.showMutationError('Could not revoke token', error);
    }
  }

  private async rotateKey(): Promise<void> {
    try {
      const result = await this.api.rotateServiceTokenKey();
      this.messages.add({
        severity: 'success',
        summary: 'Signing key rotated',
        detail: `Active key ${result.activeKid}. ${result.message}`,
        life: 6000,
      });
    } catch (error) {
      this.showMutationError('Could not rotate signing key', error);
    }
  }

  private showMutationError(summary: string, error: unknown): void {
    const failure = toApiError(error);
    this.messages.add({
      severity: 'error',
      summary,
      detail: failure.requestID
        ? `${failure.message} Request ID ${failure.requestID}.`
        : failure.message,
      life: 6000,
    });
  }
}

function emptyTokenDraft(): TokenDraft {
  return { resourceID: '', label: '', expiresInDays: '90' };
}
