import { Component, computed, inject, signal } from '@angular/core';
import { FormField, form, max, min, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import type { Platform, Resource, ResourceType } from '../../../core/api/models';
import { RESOURCE_TYPE_ORDER, resourceTypeLabel } from '../../../shared/format/labels';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate } from '../admin-format';
import { Paginator, pageSlice } from '../../../shared/ui/paginator';
import { AdminStore } from '../admin-store';
import { groupAccountsByPlatform } from '../option-groups';
import { CatalogTabs } from './catalog-tabs';
import { resolveCollectionOutcome, type CollectionRunOutcome } from './collection-run';

/**
 * How often a pending run re-reads the metric and failure tables.
 *
 * A manual run carries no retry budget, so a healthy collection reports within a second or two and
 * a failure is not far behind. Polling faster buys nothing but load on two unindexed list
 * endpoints.
 */
const POLL_INTERVAL_MS = 2_000;

/**
 * How long to wait before admitting no result is coming.
 *
 * Generous against a queue with a backlog, but bounded: with no retries in play, a job that has
 * said nothing in a minute is one nothing is going to say anything about.
 */
const VERDICT_TIMEOUT_MS = 60_000;

interface ResourceFormModel {
  readonly name: string;
  readonly type: ResourceType;
  readonly accountID: string;
  readonly collectionIntervalDays: number;
}

interface ResourceEditModel {
  readonly name: string;
  readonly type: ResourceType;
  readonly collectionIntervalDays: number;
}

/** Resource editor that mirrors collection-interval validation and triggers initial collection. */
@Component({
  selector: 'app-resource-management',
  imports: [Paginator, CatalogTabs, DialogModule, ErrorNotice, FormField, InputTextModule],
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
                        class="ins-admin-action is-secondary"
                        [disabled]="!resource.id || !collectable(resource) || running(resource)"
                        [title]="collectHint(resource)"
                        (click)="collectNow(resource)"
                      >
                        {{ running(resource) ? 'Collecting…' : 'Collect now' }}
                      </button>
                      <button
                        type="button"
                        class="ins-admin-action is-secondary"
                        [disabled]="!resource.id"
                        (click)="openEdit(resource)"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!resource.id"
                        (click)="confirmDelete($event, resource)"
                      >
                        Delete
                      </button>
                    </div>
                    @if (run(resource); as outcome) {
                      <p
                        class="ins-collect-status"
                        [attr.data-state]="outcome.state"
                        role="status"
                        aria-live="polite"
                      >
                        {{ outcome.detail }}
                      </p>
                    }
                  </td>
                </tr>
              }
            </tbody>
          </table>
          <app-paginator
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
            pInputText
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
            @for (group of accountsByPlatform(); track group.label) {
              <optgroup [label]="group.label">
                @for (option of group.options; track option.item.id) {
                  <option [value]="option.item.id">{{ option.label }}</option>
                }
              </optgroup>
            }
          </select>
          <p class="ins-admin-form__hint">
            Grouped by registry scope, matching the dashboard. Inside a scope that covers more than
            one registry — Packages — each option names its own.
          </p>
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-interval">Collection interval in days</label>
          <input
            id="resource-interval"
            pInputText
            type="number"
            inputmode="numeric"
            [formField]="resourceForm.collectionIntervalDays"
          />
          <p class="ins-admin-form__hint">
            {{
              selectedPlatform() === 'github'
                ? 'GitHub cadence is capped at 7 days, half its 14-day traffic window, so a missed collection costs hours, not the whole window.'
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

    <p-dialog
      header="Edit resource"
      closeAriaLabel="Close resource editor"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="editOpen()"
      (visibleChange)="editOpen.set($event)"
      (onHide)="resetEditForm()"
    >
      <form class="ins-admin-form" (submit)="confirmEdit($event)">
        <p class="ins-admin-secret-notice">
          Saving reschedules collection from the new interval. Moving a resource to a different
          account is not supported here — its metric history is keyed to this one.
        </p>

        <div class="ins-admin-form__field">
          <span>Account</span>
          <p class="ins-admin-form__hint">
            {{ accountName(editingResource()?.accountID) }} — not editable here.
          </p>
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-edit-name">Provider resource name or path</label>
          <input
            id="resource-edit-name"
            pInputText
            type="text"
            autocomplete="off"
            [formField]="editForm.name"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-edit-kind">Resource kind</label>
          <select id="resource-edit-kind" [formField]="editForm.type">
            @for (type of resourceTypes; track type) {
              <option [value]="type">{{ typeName(type) }}</option>
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="resource-edit-interval">Collection interval in days</label>
          <input
            id="resource-edit-interval"
            pInputText
            type="number"
            inputmode="numeric"
            [formField]="editForm.collectionIntervalDays"
          />
          <p class="ins-admin-form__hint">
            {{
              editingAccountPlatform() === 'github'
                ? 'GitHub cadence is capped at 7 days, half its 14-day traffic window, so a missed collection costs hours, not the whole window.'
                : 'This registry permits at most 30 days.'
            }}
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
          <button type="button" class="ins-admin-action is-secondary" (click)="closeEdit()">
            Cancel
          </button>
          <button type="submit" class="ins-admin-action" [disabled]="!editFormReady() || saving()">
            {{ saving() ? 'Saving…' : 'Save changes' }}
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
  protected readonly dialogStyle = { width: '31rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly createOpen = signal(false);
  protected readonly resourcePage = signal(0);
  /** Latest manual-collection outcome per resource id, for the row that triggered it. */
  protected readonly runs = signal<Record<string, CollectionRunOutcome>>({});
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly resourceModel = signal<ResourceFormModel>(emptyResourceModel());
  protected readonly sortedAccounts = computed(() =>
    [...this.store.snapshot().accounts].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly accountsByPlatform = computed(() =>
    groupAccountsByPlatform(this.store.snapshot().accounts),
  );
  protected readonly sortedResources = computed(() =>
    [...this.store.snapshot().resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly pagedResources = computed(() =>
    pageSlice(this.sortedResources(), this.resourcePage()),
  );
  protected readonly selectedPlatform = computed<Platform | null>(() => {
    const accountID = this.resourceModel().accountID;
    return (
      this.store.snapshot().accounts.find((account) => account.id === accountID)?.platform ?? null
    );
  });
  protected readonly maximumInterval = computed(() =>
    this.selectedPlatform() === 'github' ? 7 : 30,
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

  protected readonly editOpen = signal(false);
  protected readonly editingResource = signal<Resource | null>(null);
  protected readonly editModel = signal<ResourceEditModel>(emptyResourceEditModel());
  protected readonly editingAccountPlatform = computed<Platform | null>(() => {
    const accountID = this.editingResource()?.accountID;
    return (
      this.store.snapshot().accounts.find((account) => account.id === accountID)?.platform ?? null
    );
  });
  private readonly editMaximumInterval = computed(() =>
    this.editingAccountPlatform() === 'github' ? 7 : 30,
  );
  protected readonly editForm = form(this.editModel, (path) => {
    required(path.name, { message: 'Enter a resource name.' });
    min(path.collectionIntervalDays, 1, { message: 'Use at least one day.' });
    max(path.collectionIntervalDays, () => this.editMaximumInterval(), {
      message: () => `Use no more than ${this.editMaximumInterval()} days.`,
    });
  });
  protected readonly editFormReady = computed(
    () =>
      this.editForm().valid() &&
      this.editModel().collectionIntervalDays <= this.editMaximumInterval(),
  );

  protected openEdit(resource: Resource): void {
    this.editingResource.set(resource);
    this.editModel.set({
      name: resource.name ?? '',
      type: resource.type ?? 'repository',
      collectionIntervalDays: resource.collectionIntervalDays ?? 7,
    });
    this.formError.set(null);
    this.editOpen.set(true);
  }

  protected closeEdit(): void {
    this.editOpen.set(false);
    this.resetEditForm();
  }

  protected resetEditForm(): void {
    this.editingResource.set(null);
    this.editModel.set(emptyResourceEditModel());
    this.formError.set(null);
  }

  protected confirmEdit(event: SubmitEvent): void {
    event.preventDefault();
    this.editForm().markAsTouched();
    const resource = this.editingResource();
    if (!resource?.id || !this.editFormReady() || this.saving()) {
      return;
    }

    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Save changes to this resource?',
      message:
        'This overwrites the resource’s name, kind, and collection cadence. Existing metrics and releases are unaffected.',
      rejectLabel: 'Keep editing',
      acceptLabel: 'Save changes',
      acceptButtonProps: { severity: 'warn' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.saveEdit(resource),
    });
  }

  private async saveEdit(resource: Resource): Promise<void> {
    if (!resource.id) {
      return;
    }

    const model = this.editModel();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.updateResource(resource.id, {
        name: model.name.trim(),
        type: model.type,
        collectionIntervalDays: model.collectionIntervalDays,
      });
      this.messages.add({
        severity: 'success',
        summary: 'Resource updated',
        detail: `${model.name.trim()} was saved.`,
        life: 3500,
      });
      this.editOpen.set(false);
      this.resetEditForm();
      this.store.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

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

  /** Platform of the account this resource belongs to, or null when it cannot be resolved. */
  private platformOf(resource: Resource): Platform | null {
    return (
      this.store.snapshot().accounts.find((account) => account.id === resource.accountID)
        ?.platform ?? null
    );
  }

  /**
   * Mirrors `Platform.isCollectable` on the server.
   *
   * Disabled rather than hidden: ghcr, npm and pypi resources are legitimately catalogued, and a
   * button that simply is not there reads as a bug to anyone who does not already know which
   * platforms have collectors. The hint says which it is.
   */
  protected collectable(resource: Resource): boolean {
    const platform = this.platformOf(resource);
    return platform === 'github' || platform === 'huggingface' || platform === 'patra';
  }

  protected collectHint(resource: Resource): string {
    return this.collectable(resource)
      ? 'Queue a collection now, outside this resource’s schedule.'
      : 'This platform is catalogued but has no collector, so there is nothing to run.';
  }

  protected run(resource: Resource): CollectionRunOutcome | null {
    const id = resource.id;
    return id ? (this.runs()[id] ?? null) : null;
  }

  protected running(resource: Resource): boolean {
    return this.run(resource)?.state === 'running';
  }

  /**
   * Dispatches a collection and then watches for its result.
   *
   * The endpoint returns as soon as the job is queued, so the outcome has to be inferred from rows
   * the worker writes afterwards. Polling stops on the first settled verdict, including
   * `noVerdict` — see `resolveCollectionOutcome` for why that is a real answer and not a timeout
   * to hide.
   */
  protected async collectNow(resource: Resource): Promise<void> {
    const id = resource.id;
    if (!id || this.running(resource) || !this.collectable(resource)) {
      return;
    }

    this.setRun(id, { state: 'running', detail: 'Queueing collection…' });

    let dispatchedAt: string;
    try {
      dispatchedAt = (await this.api.collectResource(id)).dispatchedAt;
    } catch (error) {
      const failure = toApiError(error);
      this.setRun(id, { state: 'failed', detail: failure.message });
      return;
    }

    const startedAt = Date.now();
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));

      let outcome: CollectionRunOutcome;
      try {
        const [metrics, failures] = await Promise.all([
          this.api.loadRecentMetrics(200),
          this.api.loadJobFailures(50),
        ]);
        outcome = resolveCollectionOutcome({
          resourceID: id,
          dispatchedAt,
          metrics,
          failures,
          elapsedMs: Date.now() - startedAt,
          timeoutMs: VERDICT_TIMEOUT_MS,
        });
      } catch {
        // A failed poll says nothing about the job, which is still running on the worker. Keep
        // waiting rather than reporting a verdict this did not observe.
        outcome = { state: 'running', detail: 'Waiting for the worker to report.' };
      }

      this.setRun(id, outcome);
      if (outcome.state === 'running') {
        continue;
      }

      if (outcome.state === 'succeeded') {
        // New metrics landed, so the catalog's last-collected and due dates are stale.
        this.store.reload();
      }
      return;
    }
  }

  private setRun(id: string, outcome: CollectionRunOutcome): void {
    this.runs.update((current) => ({ ...current, [id]: outcome }));
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

function emptyResourceEditModel(): ResourceEditModel {
  return { name: '', type: 'repository', collectionIntervalDays: 7 };
}
