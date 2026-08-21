import { Component, computed, inject, signal } from '@angular/core';
import { FormField, form, max, min, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import type { Platform, Resource, ResourceType } from '../../../core/api/models';
import { RESOURCE_TYPE_ORDER, resourceTypeLabel } from '../../../shared/format/labels';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate } from '../admin-format';
import { AdminPaginator } from '../admin-paginator';
import { AdminStore } from '../admin-store';
import { CatalogTabs } from './catalog-tabs';

interface ResourceFormModel {
  readonly name: string;
  readonly type: ResourceType;
  readonly accountID: string;
  readonly collectionIntervalDays: number;
}

/** Resource editor that mirrors collection-interval validation and triggers initial collection. */
@Component({
  selector: 'app-resource-management',
  imports: [AdminPaginator, CatalogTabs, DialogModule, ErrorNotice, FormField],
  template: `
    <section class="ins-admin-page" aria-labelledby="resources-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Collectable catalog</p>
          <h2 id="resources-title">Resources</h2>
          <p>Each resource belongs to one account and carries its own collection cadence.</p>
        </div>
        <app-catalog-tabs />
        <button
          type="button"
          class="ins-admin-action"
          [disabled]="store.snapshot().accounts.length === 0"
          (click)="openCreate()"
        >
          <span aria-hidden="true">＋</span> Add resource
        </button>
      </header>

      @if (store.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="store.reload()" />
      } @else if (store.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading resources…</div>
      } @else if (store.snapshot().resources.length === 0) {
        <div class="ins-admin-empty"><p>No collectable resources are registered.</p></div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Resources in the Insights catalog
            </caption>
            <thead>
              <tr>
                <th scope="col">Resource</th>
                <th scope="col">Kind</th>
                <th scope="col">Account</th>
                <th scope="col">Cadence</th>
                <th scope="col">Next collection</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (resource of pagedResources(); track resource.id ?? resource.name) {
                <tr>
                  <th scope="row" class="ins-mono">{{ resource.name || 'Unnamed resource' }}</th>
                  <td>{{ typeName(resource.type) }}</td>
                  <td class="ins-mono">{{ accountName(resource.accountID) }}</td>
                  <td>{{ resource.collectionIntervalDays ?? '—' }} days</td>
                  <td>{{ formatDate(resource.nextCollectionAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!resource.id"
                        (click)="confirmDelete($event, resource)"
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              }
            </tbody>
          </table>
          <app-admin-paginator
            label="Resource catalog"
            [total]="sortedResources().length"
            [(page)]="resourcePage"
          />
        </div>
      }
    </section>

    <p-dialog
      header="Add collectable resource"
      closeAriaLabel="Close resource editor"
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
      <form class="ins-admin-form" (submit)="createResource($event)">
        <p class="ins-admin-secret-notice">
          Creating a resource dispatches its first collection synchronously. Saving may take longer
          than the other catalog forms; do not submit it twice.
        </p>

        <div class="ins-admin-form__field">
          <label for="resource-name">Provider resource name or path</label>
          <input
            id="resource-name"
            type="text"
            autocomplete="off"
            [formField]="resourceForm.name"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-kind">Resource kind</label>
          <select id="resource-kind" [formField]="resourceForm.type">
            @for (type of resourceTypes; track type) {
              <option [value]="type">{{ typeName(type) }}</option>
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-account">Account</label>
          <select id="resource-account" [formField]="resourceForm.accountID">
            @for (account of sortedAccounts(); track account.id ?? account.name) {
              @if (account.id) {
                <option [value]="account.id">{{ account.name }} · {{ account.platform }}</option>
              }
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-interval">Collection interval in days</label>
          <input
            id="resource-interval"
            type="number"
            inputmode="numeric"
            [formField]="resourceForm.collectionIntervalDays"
          />
          <p class="ins-admin-form__hint">
            {{
              selectedPlatform() === 'github'
                ? 'GitHub traffic history permits at most 14 days.'
                : 'This registry permits at most 30 days.'
            }}
          </p>
        </div>

        @if (resourceForm().touched() && !formReady()) {
          <p class="ins-admin-form__hint" role="alert">
            Enter a name, choose an account, and use an interval from 1 to
            {{ maximumInterval() }} days.
          </p>
        }

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
            {{ saving() ? 'Creating and collecting…' : 'Create resource' }}
          </button>
        </div>
      </form>
    </p-dialog>
  `,
  styleUrl: '../admin-records.css',
})
export class ResourceManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);

  protected readonly resourceTypes = RESOURCE_TYPE_ORDER;
  protected readonly dialogStyle = { width: '32rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly createOpen = signal(false);
  protected readonly resourcePage = signal(0);
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly resourceModel = signal<ResourceFormModel>(emptyResourceModel());
  protected readonly sortedAccounts = computed(() =>
    [...this.store.snapshot().accounts].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly sortedResources = computed(() =>
    [...this.store.snapshot().resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly pagedResources = computed(() => {
    const resources = this.sortedResources();
    const page = Math.min(this.resourcePage(), Math.max(0, Math.ceil(resources.length / 10) - 1));
    return resources.slice(page * 10, page * 10 + 10);
  });
  protected readonly selectedPlatform = computed<Platform | null>(() => {
    const accountID = this.resourceModel().accountID;
    return (
      this.store.snapshot().accounts.find((account) => account.id === accountID)?.platform ?? null
    );
  });
  protected readonly maximumInterval = computed(() =>
    this.selectedPlatform() === 'github' ? 14 : 30,
  );
  protected readonly resourceForm = form(this.resourceModel, (path) => {
    required(path.name, { message: 'Enter a resource name.' });
    required(path.accountID, { message: 'Choose an account.' });
    min(path.collectionIntervalDays, 1, { message: 'Use at least one day.' });
    max(path.collectionIntervalDays, () => this.maximumInterval(), {
      message: () => `Use no more than ${this.maximumInterval()} days.`,
    });
  });
  protected readonly formReady = computed(
    () =>
      this.resourceForm().valid() &&
      this.resourceModel().collectionIntervalDays <= this.maximumInterval(),
  );
  protected readonly formatDate = formatAdminDate;

  protected openCreate(): void {
    const accountID = this.sortedAccounts().find((account) => account.id)?.id ?? '';
    this.resourceModel.set({ ...emptyResourceModel(), accountID });
    this.formError.set(null);
    this.createOpen.set(true);
  }

  protected closeCreate(): void {
    this.createOpen.set(false);
    this.resetForm();
  }

  protected resetForm(): void {
    this.resourceModel.set(emptyResourceModel());
    this.formError.set(null);
  }

  protected async createResource(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    this.resourceForm().markAsTouched();
    if (!this.formReady() || this.saving()) {
      return;
    }

    const model = this.resourceModel();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.createResource({
        name: model.name.trim(),
        type: model.type,
        accountID: model.accountID,
        collectionIntervalDays: model.collectionIntervalDays,
      });
      this.messages.add({
        severity: 'success',
        summary: 'Resource created',
        detail: `${model.name.trim()} completed its initial collection and is scheduled.`,
        life: 4500,
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

  protected typeName(type: ResourceType | undefined): string {
    return type ? resourceTypeLabel(type) : 'Unknown kind';
  }

  protected accountName(accountID: string | undefined): string {
    return (
      this.store.snapshot().accounts.find((account) => account.id === accountID)?.name ??
      accountID ??
      'Unknown account'
    );
  }

  protected confirmDelete(event: Event, resource: Resource): void {
    if (!resource.id) {
      return;
    }
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Delete resource?',
      message: `${resource.name ?? 'This resource'} will leave the active catalog and future collection schedule.`,
      rejectLabel: 'Keep resource',
      acceptLabel: 'Delete resource',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.deleteResource(resource),
    });
  }

  private async deleteResource(resource: Resource): Promise<void> {
    if (!resource.id) {
      return;
    }
    try {
      await this.api.deleteResource(resource.id);
      this.messages.add({
        severity: 'success',
        summary: 'Resource deleted',
        detail: `${resource.name ?? 'The resource'} left the active catalog.`,
        life: 3500,
      });
      this.store.reload();
    } catch (error) {
      const failure = toApiError(error);
      this.messages.add({
        severity: 'error',
        summary: 'Could not delete resource',
        detail: failure.requestID
          ? `${failure.message} Request ID ${failure.requestID}.`
          : failure.message,
        life: 6000,
      });
    }
  }
}

function emptyResourceModel(): ResourceFormModel {
  return { name: '', type: 'repository', accountID: '', collectionIntervalDays: 7 };
}
