import { Component, inject, signal } from '@angular/core';
import { FormField, form, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import type { Account, Platform } from '../../../core/api/models';
import { PLATFORM_ORDER, platformLabel } from '../../../shared/format/labels';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate } from '../admin-format';
import { AdminStore } from '../admin-store';
import { CatalogTabs } from './catalog-tabs';

interface AccountFormModel {
  readonly name: string;
  readonly platform: Platform;
}

/** Account catalog editor using Angular Signal Forms and the API's closed platform enum. */
@Component({
  selector: 'app-account-management',
  imports: [CatalogTabs, DialogModule, ErrorNotice, FormField, InputTextModule],
  template: `
    <section class="ins-admin-page" aria-labelledby="accounts-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Catalog foundations</p>
          <h2 id="accounts-title">Platform accounts</h2>
          <p>Provider identities own resources and one optional Vault credential.</p>
        </div>
        <app-catalog-tabs />
        <button type="button" class="ins-admin-action" (click)="openCreate()">
          <span aria-hidden="true">＋</span> Add account
        </button>
      </header>

      @if (store.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="store.reload()" />
      } @else if (store.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading platform accounts…</div>
      } @else if (store.snapshot().accounts.length === 0) {
        <div class="ins-admin-empty"><p>No platform accounts are registered.</p></div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Platform accounts in the Insights catalog
            </caption>
            <thead>
              <tr>
                <th scope="col">Account</th>
                <th scope="col">Registry</th>
                <th scope="col">Resources</th>
                <th scope="col">Vault</th>
                <th scope="col">Created</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (account of store.snapshot().accounts; track account.id ?? account.name) {
                <tr>
                  <th scope="row" class="ins-mono">{{ account.name || 'Unnamed account' }}</th>
                  <td>{{ platformName(account.platform) }}</td>
                  <td class="ins-mono">{{ resourceCount(account.id) }}</td>
                  <td>{{ hasVault(account.id) ? 'Configured' : 'Not configured' }}</td>
                  <td>{{ formatDate(account.createdAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!canDelete(account)"
                        [title]="deleteTitle(account)"
                        (click)="confirmDelete($event, account)"
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
      header="Add platform account"
      closeAriaLabel="Close account editor"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="createOpen()"
      (visibleChange)="createOpen.set($event)"
      (onHide)="resetForm()"
    >
      <form class="ins-admin-form" (submit)="createAccount($event)">
        <p class="ins-admin-secret-notice">
          An account is the provider identity that owns resources and, optionally, one Vault
          credential. Create it before the resources it will hold.
        </p>

        <div class="ins-admin-form__field">
          <label for="account-name">Account or organization name</label>
          <input
            id="account-name"
            pInputText
            type="text"
            autocomplete="off"
            [formField]="accountForm.name"
          />
          @if (accountForm.name().touched() && accountForm.name().invalid()) {
            <p class="ins-admin-form__hint" role="alert">Enter a non-blank account name.</p>
          }
        </div>

        <div class="ins-admin-form__field">
          <label for="account-platform">Registry</label>
          <select id="account-platform" [formField]="accountForm.platform">
            @for (platform of platforms; track platform) {
              <option [value]="platform">{{ platformName(platform) }}</option>
            }
          </select>
          <p class="ins-admin-form__hint">
            The API normalizes the name to lowercase and prevents duplicates within a registry.
          </p>
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
          <button type="submit" class="ins-admin-action" [disabled]="saving()">
            {{ saving() ? 'Creating…' : 'Create account' }}
          </button>
        </div>
      </form>
    </p-dialog>
  `,
  styleUrl: '../admin-records.css',
})
export class AccountManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);

  protected readonly platforms = PLATFORM_ORDER;
  protected readonly dialogStyle = { width: '31rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly createOpen = signal(false);
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly accountModel = signal<AccountFormModel>(emptyAccountModel());
  protected readonly accountForm = form(this.accountModel, (path) => {
    required(path.name, { message: 'Enter an account name.' });
  });
  protected readonly formatDate = formatAdminDate;

  protected openCreate(): void {
    this.resetForm();
    this.createOpen.set(true);
  }

  protected closeCreate(): void {
    this.createOpen.set(false);
    this.resetForm();
  }

  protected resetForm(): void {
    this.accountModel.set(emptyAccountModel());
    this.formError.set(null);
  }

  protected async createAccount(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    this.accountForm().markAsTouched();
    if (!this.accountForm().valid() || this.saving()) {
      return;
    }

    const model = this.accountModel();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.createAccount({ name: model.name.trim(), platform: model.platform });
      this.messages.add({
        severity: 'success',
        summary: 'Account created',
        detail: `${model.name.trim()} is ready for resources and a Vault credential.`,
        life: 3500,
      });
      this.createOpen.set(false);
      this.resetForm();
      this.store.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected platformName(platform: Platform | undefined): string {
    return platform ? platformLabel(platform) : 'Unknown registry';
  }

  protected resourceCount(accountID: string | undefined): number {
    return this.store.snapshot().resources.filter((resource) => resource.accountID === accountID)
      .length;
  }

  protected hasVault(accountID: string | undefined): boolean {
    return this.store.snapshot().vaults.some((vault) => vault.accountID === accountID);
  }

  protected canDelete(account: Account): boolean {
    return (
      Boolean(account.id) && this.resourceCount(account.id) === 0 && !this.hasVault(account.id)
    );
  }

  protected deleteTitle(account: Account): string {
    if (!account.id) {
      return 'This record has no deletable identifier.';
    }
    if (this.resourceCount(account.id) > 0) {
      return 'Delete this account’s resources first.';
    }
    if (this.hasVault(account.id)) {
      return 'Delete this account’s Vault credential first.';
    }
    return '';
  }

  protected confirmDelete(event: Event, account: Account): void {
    if (!this.canDelete(account) || !account.id) {
      return;
    }
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Delete platform account?',
      message: `${account.name ?? 'This account'} will be removed from the active catalog.`,
      rejectLabel: 'Keep account',
      acceptLabel: 'Delete account',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.deleteAccount(account),
    });
  }

  private async deleteAccount(account: Account): Promise<void> {
    if (!account.id) {
      return;
    }
    try {
      await this.api.deleteAccount(account.id);
      this.messages.add({
        severity: 'success',
        summary: 'Account deleted',
        detail: `${account.name ?? 'The account'} left the active catalog.`,
        life: 3500,
      });
      this.store.reload();
    } catch (error) {
      this.showDeleteError(error);
    }
  }

  private showDeleteError(error: unknown): void {
    const failure = toApiError(error);
    this.messages.add({
      severity: 'error',
      summary: 'Could not delete account',
      detail: failure.requestID
        ? `${failure.message} Request ID ${failure.requestID}.`
        : failure.message,
      life: 6000,
    });
  }
}

function emptyAccountModel(): AccountFormModel {
  return { name: '', platform: 'github' };
}
