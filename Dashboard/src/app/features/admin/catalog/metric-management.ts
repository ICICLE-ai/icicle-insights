import { Component, computed, inject, resource, signal } from '@angular/core';
import { FormField, form, min, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import { RECORDABLE_METRIC_TYPES, isAllTimeMetric } from '../../../core/api/insights-api';
import type { Metric, MetricType } from '../../../core/api/models';
import { metricBaseLabel, metricLabel, metricWindowNote } from '../../../shared/format/labels';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate } from '../admin-format';
import { Paginator, pageSlice } from '../../../shared/ui/paginator';
import { AdminStore } from '../admin-store';
import { groupResourcesByPlatform } from '../option-groups';
import { CatalogTabs } from './catalog-tabs';

interface MetricFormModel {
  readonly reading: number;
  readonly type: MetricType;
  readonly resourceID: string;
}

interface MetricEditModel {
  readonly reading: number;
  readonly type: MetricType;
}

/** Manual observation editor, intentionally capped to the newest 100 audit rows. */
@Component({
  selector: 'app-metric-management',
  imports: [Paginator, CatalogTabs, DialogModule, ErrorNotice, FormField, InputTextModule],
  template: `
    <section class="ins-admin-page" aria-labelledby="metrics-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Manual observations</p>
          <h2 id="metrics-title">Metrics</h2>
          <p>Showing the newest 100 readings; routine writes should use resource-scoped tokens.</p>
        </div>
        <app-catalog-tabs />
        <button
          type="button"
          class="ins-admin-action"
          [disabled]="store.snapshot().resources.length === 0"
          (click)="openCreate()"
        >
          <span aria-hidden="true">＋</span> Record metric
        </button>
      </header>

      @if (metricData.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="metricData.reload()" />
      } @else if (metricData.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading recent metrics…</div>
      } @else if (metrics().length === 0) {
        <div class="ins-admin-empty"><p>No metric readings have been recorded.</p></div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Newest 100 metric readings
            </caption>
            <thead>
              <tr>
                <th scope="col">Recorded</th>
                <th scope="col">Resource</th>
                <th scope="col">Metric</th>
                <th scope="col">Reading</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (metric of pagedMetrics(); track metric.id ?? metric.recordedAt) {
                <tr>
                  <td>{{ formatDate(metric.recordedAt) }}</td>
                  <th scope="row" class="ins-mono">{{ resourceName(metric.resourceID) }}</th>
                  <td>{{ metricName(metric.type) }}</td>
                  <td class="ins-mono">{{ metric.reading ?? '—' }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-secondary"
                        [disabled]="!metric.id || isDerived(metric)"
                        [title]="
                          isDerived(metric)
                            ? 'All-time totals are maintained by collection and cannot be edited.'
                            : ''
                        "
                        (click)="openEdit(metric)"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!metric.id"
                        (click)="confirmDelete($event, metric)"
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              }
            </tbody>
          </table>
          <app-paginator
            label="Metric reading history"
            [total]="metrics().length"
            [(page)]="metricPage"
          />
        </div>
      }
    </section>

    <p-dialog
      header="Record metric reading"
      closeAriaLabel="Close metric editor"
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
      <form class="ins-admin-form" (submit)="createMetric($event)">
        <p class="ins-admin-secret-notice">
          The server assigns the observation timestamp and folds the reading into its all-time
          total. Use this form for corrections and administrative backstops, not as the normal
          collection path.
        </p>

        <div class="ins-admin-form__field">
          <label for="metric-resource">Resource</label>
          <select id="metric-resource" [formField]="metricForm.resourceID">
            @for (group of resourcesByPlatform(); track group.label) {
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
          <label for="metric-type">Metric type</label>
          <select id="metric-type" [formField]="metricForm.type">
            @for (type of metricTypes; track type) {
              <option [value]="type">{{ metricBaseName(type) }}</option>
            }
          </select>
          @if (windowNote(metricModel().type); as note) {
            <p class="ins-admin-form__hint">{{ note }}</p>
          }
        </div>

        <div class="ins-admin-form__field">
          <label for="metric-reading">Nonnegative reading</label>
          <input
            id="metric-reading"
            pInputText
            type="number"
            step="any"
            inputmode="decimal"
            [formField]="metricForm.reading"
          />
        </div>

        @if (metricForm().touched() && metricForm().invalid()) {
          <p class="ins-admin-form__hint" role="alert">
            Choose a resource and enter a finite value greater than or equal to zero.
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
            {{ saving() ? 'Recording…' : 'Record metric' }}
          </button>
        </div>
      </form>
    </p-dialog>

    <p-dialog
      header="Edit metric reading"
      closeAriaLabel="Close metric editor"
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
          Correcting a reading also corrects its all-time total by the difference. The observation
          timestamp and resource stay as recorded.
        </p>

        <div class="ins-admin-form__field">
          <span>Resource</span>
          <p class="ins-admin-form__hint">
            {{ resourceName(editingMetric()?.resourceID) }} — not editable here.
          </p>
        </div>

        <div class="ins-admin-form__field">
          <label for="metric-edit-type">Metric type</label>
          <select id="metric-edit-type" [formField]="editForm.type">
            @for (type of metricTypes; track type) {
              <option [value]="type">{{ metricBaseName(type) }}</option>
            }
          </select>
          @if (windowNote(editModel().type); as note) {
            <p class="ins-admin-form__hint">{{ note }}</p>
          }
        </div>

        <div class="ins-admin-form__field">
          <label for="metric-edit-reading">Nonnegative reading</label>
          <input
            id="metric-edit-reading"
            pInputText
            type="number"
            step="any"
            inputmode="decimal"
            [formField]="editForm.reading"
          />
        </div>

        @if (editForm().touched() && editForm().invalid()) {
          <p class="ins-admin-form__hint" role="alert">
            Enter a finite value greater than or equal to zero.
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
          <button type="button" class="ins-admin-action is-secondary" (click)="closeEdit()">
            Cancel
          </button>
          <button
            type="submit"
            class="ins-admin-action"
            [disabled]="editForm().invalid() || saving()"
          >
            {{ saving() ? 'Saving…' : 'Save changes' }}
          </button>
        </div>
      </form>
    </p-dialog>
  `,
  styleUrl: '../admin-records.css',
})
export class MetricManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);

  protected readonly metricTypes = RECORDABLE_METRIC_TYPES;
  protected readonly dialogStyle = { width: '31rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly createOpen = signal(false);
  protected readonly metricPage = signal(0);
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly metricModel = signal<MetricFormModel>(emptyMetricModel());
  protected readonly metricForm = form(this.metricModel, (path) => {
    required(path.resourceID, { message: 'Choose a resource.' });
    min(path.reading, 0, { message: 'Reading must be nonnegative.' });
  });
  protected readonly metricData = resource({ loader: () => this.api.loadRecentMetrics(100) });
  protected readonly metrics = computed(() =>
    [...(this.metricData.value() ?? [])].sort(
      (a, b) => Date.parse(b.recordedAt ?? '') - Date.parse(a.recordedAt ?? ''),
    ),
  );
  protected readonly pagedMetrics = computed(() => pageSlice(this.metrics(), this.metricPage()));
  protected readonly sortedResources = computed(() =>
    [...this.store.snapshot().resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly resourcesByPlatform = computed(() =>
    groupResourcesByPlatform(this.store.snapshot().resources, this.store.snapshot().accounts),
  );
  protected readonly formatDate = formatAdminDate;

  protected readonly editOpen = signal(false);
  protected readonly editingMetric = signal<Metric | null>(null);
  protected readonly editModel = signal<MetricEditModel>(emptyMetricEditModel());
  protected readonly editForm = form(this.editModel, (path) => {
    min(path.reading, 0, { message: 'Reading must be nonnegative.' });
  });

  protected openEdit(metric: Metric): void {
    this.editingMetric.set(metric);
    this.editModel.set({ reading: metric.reading ?? 0, type: metric.type ?? 'stars' });
    this.formError.set(null);
    this.editOpen.set(true);
  }

  protected closeEdit(): void {
    this.editOpen.set(false);
    this.resetEditForm();
  }

  protected resetEditForm(): void {
    this.editingMetric.set(null);
    this.editModel.set(emptyMetricEditModel());
    this.formError.set(null);
  }

  protected confirmEdit(event: SubmitEvent): void {
    event.preventDefault();
    this.editForm().markAsTouched();
    const metric = this.editingMetric();
    if (!metric?.id || !this.editForm().valid() || this.saving()) {
      return;
    }

    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Save changes to this reading?',
      message: 'This overwrites the recorded value and metric type in its time series.',
      rejectLabel: 'Keep editing',
      acceptLabel: 'Save changes',
      acceptButtonProps: { severity: 'warn' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.saveEdit(metric),
    });
  }

  private async saveEdit(metric: Metric): Promise<void> {
    if (!metric.id) {
      return;
    }

    const model = this.editModel();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.updateMetric(metric.id, { reading: model.reading, type: model.type });
      this.messages.add({
        severity: 'success',
        summary: 'Metric updated',
        detail: `${this.metricName(model.type)} was saved.`,
        life: 3500,
      });
      this.editOpen.set(false);
      this.resetEditForm();
      this.metricData.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected openCreate(): void {
    const resourceID = this.sortedResources().find((resource) => resource.id)?.id ?? '';
    this.metricModel.set({ ...emptyMetricModel(), resourceID });
    this.formError.set(null);
    this.createOpen.set(true);
  }

  protected closeCreate(): void {
    this.createOpen.set(false);
    this.resetForm();
  }

  protected resetForm(): void {
    this.metricModel.set(emptyMetricModel());
    this.formError.set(null);
  }

  protected async createMetric(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    this.metricForm().markAsTouched();
    if (!this.metricForm().valid() || this.saving()) {
      return;
    }

    const model = this.metricModel();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.createMetric(model);
      this.messages.add({
        severity: 'success',
        summary: 'Metric recorded',
        detail: `${metricLabel(model.type)} was recorded for ${this.resourceName(model.resourceID)}.`,
        life: 3500,
      });
      this.createOpen.set(false);
      this.resetForm();
      this.metricData.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

  protected resourceName(resourceID: string | undefined): string {
    return (
      this.store.snapshot().resources.find((resource) => resource.id === resourceID)?.name ??
      resourceID ??
      'Unknown resource'
    );
  }

  /** Qualified name, for the table: a reading shown without its window reads as a total. */
  protected metricName(type: MetricType | undefined): string {
    return type ? metricLabel(type) : 'Unknown metric';
  }

  /** Bare name, for the pickers, where every option is a metric and the qualifier is noise. */
  protected readonly metricBaseName = metricBaseLabel;

  /** The window sentence shown under a picker, replacing the qualifier dropped from the label. */
  protected readonly windowNote = metricWindowNote;

  /** All-time rows are server-derived; the API rejects a write naming one. */
  protected isDerived(metric: Metric): boolean {
    return metric.type !== undefined && isAllTimeMetric(metric.type);
  }

  protected confirmDelete(event: Event, metric: Metric): void {
    if (!metric.id) {
      return;
    }
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: this.isDerived(metric) ? 'Delete all-time total?' : 'Delete metric reading?',
      // Deleting a total is the only correction path left now that editing one is blocked, but
      // it does not reset the collector: `MetricWatermark.countedThrough` still marks those days
      // as folded, so the rebuilt row starts from the next uncounted day, not from zero.
      message: this.isDerived(metric)
        ? `${metricNameForConfirmation(metric)} will be removed. Collection rebuilds the total from the days after its watermark, not from zero, so the figure will restart low.`
        : `${metricNameForConfirmation(metric)} will be permanently removed from its time series.`,
      rejectLabel: 'Keep reading',
      acceptLabel: 'Delete reading',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.deleteMetric(metric),
    });
  }

  private async deleteMetric(metric: Metric): Promise<void> {
    if (!metric.id) {
      return;
    }
    try {
      await this.api.deleteMetric(metric.id);
      this.messages.add({
        severity: 'success',
        summary: 'Metric deleted',
        detail: `${this.metricName(metric.type)} was removed from the series.`,
        life: 3500,
      });
      this.metricData.reload();
    } catch (error) {
      const failure = toApiError(error);
      this.messages.add({
        severity: 'error',
        summary: 'Could not delete metric',
        detail: failure.requestID
          ? `${failure.message} Request ID ${failure.requestID}.`
          : failure.message,
        life: 6000,
      });
    }
  }
}

function emptyMetricModel(): MetricFormModel {
  return { reading: 0, type: 'stars', resourceID: '' };
}

function emptyMetricEditModel(): MetricEditModel {
  return { reading: 0, type: 'stars' };
}

function metricNameForConfirmation(metric: Metric): string {
  const type = metric.type ? metricLabel(metric.type) : 'This reading';
  return metric.reading === undefined ? type : `${type} value ${metric.reading}`;
}
