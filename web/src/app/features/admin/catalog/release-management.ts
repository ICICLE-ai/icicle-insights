import { Component, computed, inject, resource, signal } from '@angular/core';
import { FormField, form, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import type { Release } from '../../../core/api/models';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate } from '../admin-format';
import { AdminPaginator } from '../admin-paginator';
import { AdminStore } from '../admin-store';
import { CatalogTabs } from './catalog-tabs';

interface ReleaseFormModel {
  readonly version: string;
  readonly resourceID: string;
  readonly releaseMonth: string;
}

/** Monthly release-record editor; free-form version strings remain intentionally supported. */
@Component({
  selector: 'app-release-management',
  imports: [AdminPaginator, CatalogTabs, DialogModule, ErrorNotice, FormField],
  template: `
    <section class="ins-admin-page" aria-labelledby="releases-title">
      <header class="ins-admin-page__header">
        <div>
          <p class="ins-eyebrow">Publication history</p>
          <h2 id="releases-title">Software releases</h2>
          <p>Versions are free text; release time is normalized to a calendar month.</p>
        </div>
        <app-catalog-tabs />
        <button
          type="button"
          class="ins-admin-action"
          [disabled]="store.snapshot().resources.length === 0"
          (click)="openCreate()"
        >
          <span aria-hidden="true">＋</span> Record release
        </button>
      </header>

      @if (releaseData.error(); as failure) {
        <app-error-notice [error]="failure" (retry)="releaseData.reload()" />
      } @else if (releaseData.isLoading()) {
        <div class="ins-admin-loading" role="status">Loading releases…</div>
      } @else if (releases().length === 0) {
        <div class="ins-admin-empty"><p>No software releases have been recorded.</p></div>
      } @else {
        <div class="ins-admin-panel">
          <table class="ins-admin-table">
            <caption class="ins-visually-hidden">
              Software releases, newest first
            </caption>
            <thead>
              <tr>
                <th scope="col">Version</th>
                <th scope="col">Resource</th>
                <th scope="col">Release month</th>
                <th scope="col"><span class="ins-visually-hidden">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              @for (release of pagedReleases(); track release.id ?? release.version) {
                <tr>
                  <th scope="row" class="ins-mono">{{ release.version || 'Unnamed release' }}</th>
                  <td class="ins-mono">{{ resourceName(release.resourceID) }}</td>
                  <td>{{ formatDate(release.releasedAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-danger"
                        [disabled]="!release.id"
                        (click)="confirmDelete($event, release)"
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
            label="Software release history"
            [total]="releases().length"
            [(page)]="releasePage"
          />
        </div>
      }
    </section>

    <p-dialog
      header="Record software release"
      closeAriaLabel="Close release editor"
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
      <form class="ins-admin-form" (submit)="createRelease($event)">
        <div class="ins-admin-form__field">
          <label for="release-version">Version or release identifier</label>
          <input
            id="release-version"
            type="text"
            autocomplete="off"
            placeholder="v1.2.3, latest, or 2026-08"
            [formField]="releaseForm.version"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="release-resource">Resource</label>
          <select id="release-resource" [formField]="releaseForm.resourceID">
            @for (resource of sortedResources(); track resource.id ?? resource.name) {
              @if (resource.id) {
                <option [value]="resource.id">{{ resource.name || resource.id }}</option>
              }
            }
          </select>
        </div>

        <div class="ins-admin-form__field">
          <label for="release-month">Release month</label>
          <input id="release-month" type="month" [formField]="releaseForm.releaseMonth" />
        </div>

        @if (releaseForm().touched() && !formReady()) {
          <p class="ins-admin-form__hint" role="alert">
            Enter a version, choose a resource, and provide a valid release month.
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
            {{ saving() ? 'Recording…' : 'Record release' }}
          </button>
        </div>
      </form>
    </p-dialog>
  `,
  styleUrl: '../admin-records.css',
})
export class ReleaseManagement {
  protected readonly store = inject(AdminStore);
  private readonly api = inject(AdminApi);
  private readonly confirmations = inject(ConfirmationService);
  private readonly messages = inject(MessageService);

  protected readonly dialogStyle = { width: '31rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly createOpen = signal(false);
  protected readonly releasePage = signal(0);
  protected readonly saving = signal(false);
  protected readonly formError = signal<ApiError | null>(null);
  protected readonly releaseModel = signal<ReleaseFormModel>(emptyReleaseModel());
  protected readonly releaseForm = form(this.releaseModel, (path) => {
    required(path.version, { message: 'Enter a release identifier.' });
    required(path.resourceID, { message: 'Choose a resource.' });
    required(path.releaseMonth, { message: 'Choose a release month.' });
  });
  protected readonly releaseData = resource({ loader: () => this.api.loadReleases() });
  protected readonly releases = computed(() =>
    [...(this.releaseData.value() ?? [])].sort(
      (a, b) => Date.parse(b.releasedAt ?? '') - Date.parse(a.releasedAt ?? ''),
    ),
  );
  protected readonly pagedReleases = computed(() => {
    const releases = this.releases();
    const page = Math.min(this.releasePage(), Math.max(0, Math.ceil(releases.length / 10) - 1));
    return releases.slice(page * 10, page * 10 + 10);
  });
  protected readonly sortedResources = computed(() =>
    [...this.store.snapshot().resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly formReady = computed(
    () =>
      this.releaseForm().valid() && parseReleaseMonth(this.releaseModel().releaseMonth) !== null,
  );
  protected readonly formatDate = formatAdminDate;

  protected openCreate(): void {
    const resourceID = this.sortedResources().find((resource) => resource.id)?.id ?? '';
    this.releaseModel.set({ ...emptyReleaseModel(), resourceID });
    this.formError.set(null);
    this.createOpen.set(true);
  }

  protected closeCreate(): void {
    this.createOpen.set(false);
    this.resetForm();
  }

  protected resetForm(): void {
    this.releaseModel.set(emptyReleaseModel());
    this.formError.set(null);
  }

  protected async createRelease(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    this.releaseForm().markAsTouched();
    const model = this.releaseModel();
    const month = parseReleaseMonth(model.releaseMonth);
    if (!this.formReady() || !month || this.saving()) {
      return;
    }

    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.createRelease({
        version: model.version.trim(),
        resourceID: model.resourceID,
        year: month.year,
        month: month.month,
      });
      this.messages.add({
        severity: 'success',
        summary: 'Release recorded',
        detail: `${model.version.trim()} is now part of the software-release history.`,
        life: 3500,
      });
      this.createOpen.set(false);
      this.resetForm();
      this.releaseData.reload();
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

  protected confirmDelete(event: Event, release: Release): void {
    if (!release.id) {
      return;
    }
    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Delete release record?',
      message: `${release.version ?? 'This release'} will be permanently removed from the history.`,
      rejectLabel: 'Keep release',
      acceptLabel: 'Delete release',
      acceptButtonProps: { severity: 'danger' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.deleteRelease(release),
    });
  }

  private async deleteRelease(release: Release): Promise<void> {
    if (!release.id) {
      return;
    }
    try {
      await this.api.deleteRelease(release.id);
      this.messages.add({
        severity: 'success',
        summary: 'Release deleted',
        detail: `${release.version ?? 'The release'} was removed.`,
        life: 3500,
      });
      this.releaseData.reload();
    } catch (error) {
      const failure = toApiError(error);
      this.messages.add({
        severity: 'error',
        summary: 'Could not delete release',
        detail: failure.requestID
          ? `${failure.message} Request ID ${failure.requestID}.`
          : failure.message,
        life: 6000,
      });
    }
  }
}

function emptyReleaseModel(): ReleaseFormModel {
  return { version: '', resourceID: '', releaseMonth: new Date().toISOString().slice(0, 7) };
}

function parseReleaseMonth(
  value: string,
): { readonly year: number; readonly month: number } | null {
  const match = /^(\d{4})-(\d{2})$/u.exec(value);
  if (!match) {
    return null;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  return year >= 1970 && year <= 2100 && month >= 1 && month <= 12 ? { year, month } : null;
}
