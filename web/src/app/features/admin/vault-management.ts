import { Component, computed, inject, signal } from '@angular/core';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { toApiError, type ApiError } from '../../core/api/api-error';
import type { Vault } from '../../core/api/models';
import { ErrorNotice } from '../../shared/ui/error-notice';
import { AdminApi } from './admin-api';
import { expirationFromInput, formatAdminDate, futureDateInput } from './admin-format';
import { AdminStore } from './admin-store';

interface VaultDraft {
  readonly name: string;
  readonly accountID: string;
  readonly token: string;
  readonly expiresAt: string;
}

interface RotateDraft {
  readonly token: string;
  readonly expiresAt: string;
}

/** Creates, rotates, and removes Tapis Vault credentials without ever reading a stored secret. */
@Component({
  selector: 'app-vault-management',
  imports: [DialogModule, ErrorNotice, InputTextModule],
  template: `
    <section class="ins-admin-page" aria-labelledby="vaults-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Credential inventory</p>
          <h2 id="vaults-title">Tapis Vault credentials</h2>
          <p>Rotate platform access before its operational expiry window closes.</p>
        </div>
        <button
          type="button"
          class="ins-admin-action"
          [disabled]="store.snapshot().accounts.length === 0"
          (click)="openCreate()"
        >
          <span aria-hidden="true">＋</span> Add credential
        </button>
      </header>

      @if (store.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="store.reload()" />
      } @else if (store.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading vault metadata…</div>
      } @else if (store.snapshot().vaults.length === 0) {
        <div class="ins-admin-empty">
          <p>No Vault credentials are registered. Add one after an account exists.</p>
        </div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Tapis Vault credential metadata. Secret values are never returned.
            </caption>
            <thead>
              <tr>
                <th scope="col">Credential</th>
                <th scope="col">Account</th>
                <th scope="col">Expires</th>
                <th scope="col">Last rotated</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (vault of store.snapshot().vaults; track vault.id ?? vault.name) {
                <tr>
                  <th scope="row" class="ins-mono">{{ vault.name || 'Unnamed credential' }}</th>
                  <td>{{ accountName(vault.accountID) }}</td>
                  <td>
                    <span
                      class="ins-admin-status"
                      [class.is-warning]="expiryTone(vault) === 'warning'"
                      [class.is-critical]="expiryTone(vault) === 'critical'"
                    >
                      {{ formatDate(vault.expiresAt) }}
                    </span>
                  </td>
                  <td>{{ formatDate(vault.updatedAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-secondary"
                        [disabled]="!vault.id"
                        (click)="openRotate(vault)"
                      >
                        Rotate
                      </button>
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!vault.id"
                        (click)="confirmDelete($event, vault)"
                      >
                        Delete
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
      header="Add Vault credential"
      closeAriaLabel="Close credential editor"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="createOpen()"
      (visibleChange)="setCreateVisibility($event)"
      (onHide)="clearCreateSecret()"
    >
      <form class="ins-admin-form" (submit)="createVault($event)">
        <p class="ins-admin-secret-notice">
          The token is written directly to Tapis Vault. Insights stores only its name, account, and
          expiry date; the secret cannot be read back from this screen.
        </p>

        <div class="ins-admin-form__field">
          <label for="vault-name">Credential name</label>
          <input
            id="vault-name"
            pInputText
            type="text"
            autocomplete="off"
            [value]="draft().name"
            (input)="updateCreate('name', $event)"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="vault-account">Account</label>
          <select
            id="vault-account"
            [value]="draft().accountID"
            (change)="updateCreate('accountID', $event)"
          >
            @for (account of store.snapshot().accounts; track account.id ?? account.name) {
              @if (account.id) {
                <option [value]="account.id">{{ account.name || account.id }}</option>
              }
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="vault-token">Platform token</label>
          <input
            id="vault-token"
            pInputText
            type="password"
            autocomplete="new-password"
            autocapitalize="off"
            spellcheck="false"
            [value]="draft().token"
            (input)="updateCreate('token', $event)"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="vault-expiry">Expiration date</label>
          <input
            id="vault-expiry"
            type="date"
            [min]="minimumExpiry"
            [value]="draft().expiresAt"
            (input)="updateCreate('expiresAt', $event)"
          />
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
          <button type="button" class="ins-admin-action is-secondary" (click)="closeCreate()">
            Cancel
          </button>
          <button type="submit" class="ins-admin-action" [disabled]="!canCreate() || saving()">
            {{ saving() ? 'Saving…' : 'Save to Vault' }}
          </button>
        </div>
      </form>
    </p-dialog>

    <p-dialog
      header="Rotate Vault credential"
      closeAriaLabel="Close credential rotation"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="rotateOpen()"
      (visibleChange)="setRotateVisibility($event)"
      (onHide)="clearRotateSecret()"
    >
      <form class="ins-admin-form" (submit)="rotateVault($event)">
        <p class="ins-admin-secret-notice">
          Replaces <strong>{{ rotatingVault()?.name }}</strong> in Tapis Vault and records the new
          expiry as one operation. The replacement token is cleared as soon as you submit.
        </p>

        <div class="ins-admin-form__field">
          <label for="rotate-vault-token">Replacement token</label>
          <input
            id="rotate-vault-token"
            pInputText
            type="password"
            autocomplete="new-password"
            autocapitalize="off"
            spellcheck="false"
            [value]="rotateDraft().token"
            (input)="updateRotate('token', $event)"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="rotate-vault-expiry">New expiration date</label>
          <input
            id="rotate-vault-expiry"
            type="date"
            [min]="minimumExpiry"
            [value]="rotateDraft().expiresAt"
            (input)="updateRotate('expiresAt', $event)"
          />
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
          <button type="button" class="ins-admin-action is-secondary" (click)="closeRotate()">
            Cancel
          </button>
          <button type="submit" class="ins-admin-action" [disabled]="!canRotate() || saving()">
            {{ saving() ? 'Rotating…' : 'Rotate credential' }}
          </button>
        </div>
      </form>
    </p-dialog>
  `,
  styleUrl: './admin-records.css',
})
export class VaultManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);

  protected readonly minimumExpiry = futureDateInput(1);
  protected readonly dialogStyle = { width: '31rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly createOpen = signal(false);
  protected readonly rotateOpen = signal(false);
  protected readonly rotatingVault = signal<Vault | null>(null);
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly draft = signal<VaultDraft>(emptyVaultDraft());
  protected readonly rotateDraft = signal<RotateDraft>(emptyRotateDraft());

  protected readonly canCreate = computed(() => {
    const draft = this.draft();
    return (
      draft.name.trim().length > 0 &&
      draft.accountID.length > 0 &&
      draft.token.trim().length > 0 &&
      expirationFromInput(draft.expiresAt) !== null
    );
  });

  protected readonly canRotate = computed(() => {
    const draft = this.rotateDraft();
    return (
      Boolean(this.rotatingVault()?.id) &&
      draft.token.trim().length > 0 &&
      expirationFromInput(draft.expiresAt) !== null
    );
  });

  protected readonly formatDate = formatAdminDate;

  protected openCreate(): void {
    const accountID = this.store.snapshot().accounts.find((account) => account.id)?.id ?? '';
    this.draft.set({ ...emptyVaultDraft(), accountID });
    this.formError.set(null);
    this.createOpen.set(true);
  }

  protected closeCreate(): void {
    this.createOpen.set(false);
    this.clearCreateSecret();
  }

  protected setCreateVisibility(visible: boolean): void {
    this.createOpen.set(visible);
  }

  protected clearCreateSecret(): void {
    this.draft.update((draft) => ({ ...draft, token: '' }));
    this.formError.set(null);
  }

  protected openRotate(vault: Vault): void {
    if (!vault.id) {
      return;
    }
    this.rotatingVault.set(vault);
    this.rotateDraft.set(emptyRotateDraft());
    this.formError.set(null);
    this.rotateOpen.set(true);
  }

  protected closeRotate(): void {
    this.rotateOpen.set(false);
    this.clearRotateSecret();
  }

  protected setRotateVisibility(visible: boolean): void {
    this.rotateOpen.set(visible);
  }

  protected clearRotateSecret(): void {
    this.rotateDraft.update((draft) => ({ ...draft, token: '' }));
    this.rotatingVault.set(null);
    this.formError.set(null);
  }

  protected updateCreate(field: keyof VaultDraft, event: Event): void {
    const value = (event.target as HTMLInputElement | HTMLSelectElement).value;
    this.draft.update((draft) => ({ ...draft, [field]: value }));
  }

  protected updateRotate(field: keyof RotateDraft, event: Event): void {
    const value = (event.target as HTMLInputElement).value;
    this.rotateDraft.update((draft) => ({ ...draft, [field]: value }));
  }

  protected async createVault(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!this.canCreate() || this.saving()) {
      return;
    }

    const draft = this.draft();
    const expires = expirationFromInput(draft.expiresAt);
    if (!expires) {
      return;
    }

    this.saving.set(true);
    this.formError.set(null);
    this.draft.update((current) => ({ ...current, token: '' }));
    try {
      await this.api.createVault({
        name: draft.name.trim(),
        accountID: draft.accountID,
        token: draft.token.trim(),
        expires,
      });
      this.messages.add({
        severity: 'success',
        summary: 'Credential stored',
        detail: `${draft.name.trim()} is now referenced in Insights.`,
        life: 3500,
      });
      this.createOpen.set(false);
      this.draft.set(emptyVaultDraft());
      this.store.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected async rotateVault(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const vault = this.rotatingVault();
    const draft = this.rotateDraft();
    const expires = expirationFromInput(draft.expiresAt);
    if (!vault?.id || !expires || !this.canRotate() || this.saving()) {
      return;
    }

    this.saving.set(true);
    this.formError.set(null);
    this.rotateDraft.update((current) => ({ ...current, token: '' }));
    try {
      await this.api.rotateVault(vault.id, { token: draft.token.trim(), expires });
      this.messages.add({
        severity: 'success',
        summary: 'Credential rotated',
        detail: `${vault.name ?? 'Vault credential'} now uses the replacement token.`,
        life: 3500,
      });
      this.rotateOpen.set(false);
      this.rotatingVault.set(null);
      this.store.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected confirmDelete(event: Event, vault: Vault): void {
    if (!vault.id) {
      return;
    }

    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Delete Vault credential?',
      message: `This deletes ${vault.name ?? 'this credential'} metadata and destroys its secret in Tapis Vault. This cannot be undone.`,
      rejectLabel: 'Keep credential',
      acceptLabel: 'Delete credential',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.deleteVault(vault),
    });
  }

  protected accountName(accountID: string | undefined): string {
    const account = this.store.snapshot().accounts.find((entry) => entry.id === accountID);
    return account?.name ?? accountID ?? 'Unknown account';
  }

  protected expiryTone(vault: Vault): 'good' | 'warning' | 'critical' {
    const time = Date.parse(vault.expiresAt ?? '');
    if (!Number.isFinite(time) || time <= Date.now()) {
      return 'critical';
    }
    return time <= Date.now() + 30 * 24 * 60 * 60 * 1_000 ? 'warning' : 'good';
  }

  private async deleteVault(vault: Vault): Promise<void> {
    if (!vault.id) {
      return;
    }

    try {
      await this.api.deleteVault(vault.id);
      this.messages.add({
        severity: 'success',
        summary: 'Credential deleted',
        detail: `${vault.name ?? 'Vault credential'} and its Tapis Vault secret were removed.`,
        life: 3500,
      });
      this.store.reload();
    } catch (error) {
      const failure = toApiError(error);
      this.messages.add({
        severity: 'error',
        summary: 'Could not delete credential',
        detail: failure.requestID
          ? `${failure.message} Request ID ${failure.requestID}.`
          : failure.message,
        life: 6000,
      });
    }
  }
}

function emptyVaultDraft(): VaultDraft {
  return { name: '', accountID: '', token: '', expiresAt: futureDateInput(90) };
}

function emptyRotateDraft(): RotateDraft {
  return { token: '', expiresAt: futureDateInput(90) };
}
