import { Component, computed, inject, signal } from '@angular/core';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';
import { Router } from '@angular/router';

import { toApiError, type ApiError } from '../../core/api/api-error';
import type { Admin } from '../../core/api/models';
import { SessionStore } from '../../core/auth/session-store';
import { ErrorNotice } from '../../shared/ui/error-notice';
import { AdminApi } from './admin-api';
import { formatAdminDate } from './admin-format';
import { AdminStore } from './admin-store';

/** Grants and revokes administrator usernames while protecting the root recovery identity. */
@Component({
  selector: 'app-administrator-management',
  imports: [DialogModule, ErrorNotice, InputTextModule],
  template: `
    <section class="ins-admin-page" aria-labelledby="administrators-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Access control</p>
          <h2 id="administrators-title">Administrators</h2>
          <p>Grant access by Tapis username; the environment root remains the recovery path.</p>
        </div>
        <button type="button" class="ins-admin-action" (click)="openAdd()">
          <span aria-hidden="true">＋</span> Add administrator
        </button>
      </header>

      @if (store.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="store.reload()" />
      } @else if (store.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading administrator access…</div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Tapis usernames with Insights administrator access
            </caption>
            <thead>
              <tr>
                <th scope="col">Username</th>
                <th scope="col">Access source</th>
                <th scope="col">Granted by</th>
                <th scope="col">Granted</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (admin of store.snapshot().admins; track admin.id ?? admin.username) {
                <tr>
                  <th scope="row" class="ins-mono">
                    {{ admin.username || 'Unnamed administrator' }}
                    @if (admin.username === session.username()) {
                      <span class="ins-admin-badge">You</span>
                    }
                  </th>
                  <td>
                    @if (admin.isRoot) {
                      <span class="ins-admin-badge">Protected root</span>
                    } @else {
                      Granted record
                    }
                  </td>
                  <td class="ins-mono">{{ admin.addedBy || 'Environment' }}</td>
                  <td>{{ formatDate(admin.createdAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!admin.id || Boolean(admin.isRoot)"
                        [title]="
                          admin.isRoot
                            ? 'The root administrator cannot be removed through the API.'
                            : ''
                        "
                        (click)="confirmRemove($event, admin)"
                      >
                        {{ admin.isRoot ? 'Protected' : 'Remove' }}
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
      header="Add administrator"
      closeAriaLabel="Close administrator editor"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="addOpen()"
      (visibleChange)="setAddVisibility($event)"
      (onHide)="resetForm()"
    >
      <form class="ins-admin-form" (submit)="addAdministrator($event)">
        <p class="ins-admin-secret-notice">
          Enter the bare <code>tapis/username</code>, not an email address or the
          <code>user&#64;tenant</code> subject form. Access takes effect on the next API request.
        </p>

        <div class="ins-admin-form__field">
          <label for="admin-username">Tapis username</label>
          <input
            id="admin-username"
            pInputText
            type="text"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            [value]="username()"
            (input)="updateUsername($event)"
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
          <button type="button" class="ins-admin-action is-secondary" (click)="closeAdd()">
            Cancel
          </button>
          <button type="submit" class="ins-admin-action" [disabled]="!canAdd() || saving()">
            {{ saving() ? 'Granting…' : 'Grant access' }}
          </button>
        </div>
      </form>
    </p-dialog>
  `,
  styleUrl: './admin-records.css',
})
export class AdministratorManagement {
  protected readonly store = inject(AdminStore);
  protected readonly session = inject(SessionStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);
  private readonly router = inject(Router);

  protected readonly dialogStyle = { width: '31rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly addOpen = signal(false);
  protected readonly username = signal('');
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly formatDate = formatAdminDate;
  protected readonly Boolean = Boolean;
  protected readonly canAdd = computed(() => this.username().trim().length > 0);

  protected openAdd(): void {
    this.resetForm();
    this.addOpen.set(true);
  }

  protected closeAdd(): void {
    this.addOpen.set(false);
    this.resetForm();
  }

  protected setAddVisibility(visible: boolean): void {
    this.addOpen.set(visible);
  }

  protected resetForm(): void {
    this.username.set('');
    this.formError.set(null);
  }

  protected updateUsername(event: Event): void {
    this.username.set((event.target as HTMLInputElement).value);
  }

  protected async addAdministrator(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!this.canAdd() || this.saving()) {
      return;
    }

    const username = this.username().trim();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.createAdmin(username);
      this.messages.add({
        severity: 'success',
        summary: 'Administrator added',
        detail: `${username} can administer Insights on their next request.`,
        life: 3500,
      });
      this.addOpen.set(false);
      this.resetForm();
      this.store.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected confirmRemove(event: Event, admin: Admin): void {
    if (!admin.id || admin.isRoot) {
      return;
    }

    const removingSelf = admin.username === this.session.username();
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: removingSelf ? 'Remove your own access?' : 'Remove administrator?',
      message: removingSelf
        ? 'Your access will end immediately after this request and the console will close.'
        : `${admin.username ?? 'This user'} will lose administrator access on their next API request.`,
      rejectLabel: 'Keep access',
      acceptLabel: 'Remove access',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.removeAdministrator(admin),
    });
  }

  private async removeAdministrator(admin: Admin): Promise<void> {
    if (!admin.id) {
      return;
    }

    try {
      await this.api.deleteAdmin(admin.id);
      this.messages.add({
        severity: 'success',
        summary: 'Administrator removed',
        detail: `${admin.username ?? 'The selected user'} no longer has stored admin access.`,
        life: 3500,
      });
      this.store.reload();

      if (admin.username === this.session.username()) {
        await this.session.probe();
        if (!this.session.isAdmin()) {
          await this.router.navigate(['/admin-access'], {
            queryParams: { state: this.session.status() },
          });
        }
      }
    } catch (error) {
      const failure = toApiError(error);
      this.messages.add({
        severity: 'error',
        summary: 'Could not remove administrator',
        detail: failure.requestID
          ? `${failure.message} Request ID ${failure.requestID}.`
          : failure.message,
        life: 6000,
      });
    }
  }
}
