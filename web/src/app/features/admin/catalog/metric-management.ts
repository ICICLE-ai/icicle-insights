import { Component, computed, inject, resource, signal } from '@angular/core';
import { FormField, form, min, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import { ALL_METRIC_TYPES } from '../../../core/api/insights-api';
import type { Metric, MetricType } from '../../../core/api/models';
import { metricLabel } from '../../../shared/format/labels';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate } from '../admin-format';
import { AdminPaginator } from '../admin-paginator';
import { AdminStore } from '../admin-store';
import { CatalogTabs } from './catalog-tabs';

interface MetricFormModel {
  readonly reading: number;
  readonly type: MetricType;
  readonly resourceID: string;
}

/** Manual observation editor, intentionally capped to the newest 100 audit rows. */
@Component({
  selector: 'app-metric-management',
  imports: [AdminPaginator, CatalogTabs, DialogModule, ErrorNotice, FormField],
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
          <app-admin-paginator
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
          The server assigns the observation timestamp. Use this form for corrections and
          administrative backstops, not as the normal collection path.
        </p>

        <div class="ins-admin-form__field">
          <label for="metric-resource">Resource</label>
          <select id="metric-resource" [formField]="metricForm.resourceID">
            @for (resource of sortedResources(); track resource.id ?? resource.name) {
              @if (resource.id) {
                <option [value]="resource.id">{{ resource.name || resource.id }}</option>
              }
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="metric-type">Metric type</label>
          <select id="metric-type" [formField]="metricForm.type">
            @for (type of metricTypes; track type) {
              <option [value]="type">{{ metricName(type) }}</option>
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="metric-reading">Nonnegative reading</label>
          <input
            id="metric-reading"
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
  `,
  styleUrl: '../admin-records.css',
})
export class MetricManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);

  protected readonly metricTypes = ALL_METRIC_TYPES;
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
  protected readonly pagedMetrics = computed(() => {
    const metrics = this.metrics();
    const page = Math.min(this.metricPage(), Math.max(0, Math.ceil(metrics.length / 10) - 1));
    return metrics.slice(page * 10, page * 10 + 10);
  });
  protected readonly sortedResources = computed(() =>
    [...this.store.snapshot().resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly formatDate = formatAdminDate;

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

  protected metricName(type: MetricType | undefined): string {
    return type ? metricLabel(type) : 'Unknown metric';
  }

  protected confirmDelete(event: Event, metric: Metric): void {
    if (!metric.id) {
      return;
    }
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Delete metric reading?',
      message: `${metricNameForConfirmation(metric)} will be permanently removed from its time series.`,
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

function metricNameForConfirmation(metric: Metric): string {
  const type = metric.type ? metricLabel(metric.type) : 'This reading';
  return metric.reading === undefined ? type : `${type} value ${metric.reading}`;
}
