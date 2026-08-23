import { Component, computed, inject, resource, signal } from '@angular/core';
import { FormField, form, required } from '@angular/forms/signals';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { toApiError, type ApiError } from '../../../core/api/api-error';
import type { Release } from '../../../core/api/models';
import { ErrorNotice } from '../../../shared/ui/error-notice';
import { AdminApi } from '../admin-api';
import { formatAdminDate, formatAdminMonth } from '../admin-format';
import { Paginator, pageSlice } from '../../../shared/ui/paginator';
import { AdminStore } from '../admin-store';
import { groupResourcesByPlatform } from '../option-groups';
import { CatalogTabs } from './catalog-tabs';
import { MONTH_OPTIONS, currentYearMonth, releaseYearOptions, toYearMonth } from './release-month';

interface ReleaseFormModel {
  readonly version: string;
  readonly resourceID: string;
  readonly releaseYear: string;
  readonly releaseMonth: string;
}

interface ReleaseEditModel {
  readonly version: string;
  readonly releaseYear: string;
  readonly releaseMonth: string;
}

/** Monthly release-record editor; free-form version strings remain intentionally supported. */
@Component({
  selector: 'app-release-management',
  imports: [Paginator, CatalogTabs, DialogModule, ErrorNotice, FormField, InputTextModule],
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
                  <td>{{ formatMonth(release.releasedAt) }}</td>
                  <td>
                    <div class="ins-admin-table__actions">
                      <button
                        type="button"
                        class="ins-admin-action is-secondary"
                        [disabled]="!release.id"
                        (click)="openEdit(release)"
                      >
                        Edit
                      </button>
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
          <app-paginator
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
        <p class="ins-admin-secret-notice">
          Release time is stored as a calendar month, not a day — the dashboard's cadence view
          counts releases per month. The version string itself is free text.
        </p>

        <div class="ins-admin-form__field">
          <label for="release-version">Version or release identifier</label>
          <input
            id="release-version"
            pInputText
            type="text"
            autocomplete="off"
            placeholder="v1.2.3, latest, or 2026-08"
            [formField]="releaseForm.version"
          />
        </div>

        <div class="ins-admin-form__field">
          <label for="release-resource">Resource</label>
          <select id="release-resource" [formField]="releaseForm.resourceID">
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
          <span id="release-month-label">Release month</span>
          <div class="ins-admin-form__row" role="group" aria-labelledby="release-month-label">
            <select
              id="release-month"
              aria-label="Release month"
              [formField]="releaseForm.releaseMonth"
            >
              @for (month of monthOptions; track month.value) {
                <option [value]="month.value">{{ month.label }}</option>
              }
            </select>
            <select
              id="release-year"
              aria-label="Release year"
              [formField]="releaseForm.releaseYear"
            >
              @for (year of createYearOptions(); track year) {
                <option [value]="year">{{ year }}</option>
              }
            </select>
          </div>
        </div>

        @if (releaseForm().touched() && !formReady()) {
          <p class="ins-admin-form__hint" role="alert">Enter a version and choose a resource.</p>
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

    <p-dialog
      header="Edit release"
      closeAriaLabel="Close release editor"
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
          Saving overwrites the recorded version and release month. Moving a release to a different
          resource is not supported here — delete it and record it again.
        </p>

        <div class="ins-admin-form__field">
          <span>Resource</span>
          <p class="ins-admin-form__hint">
            {{ resourceName(editingRelease()?.resourceID) }} — not editable here.
          </p>
        </div>

        <div class="ins-admin-form__field">
          <label for="release-edit-version">Version or release identifier</label>
          <input
            id="release-edit-version"
            pInputText
            type="text"
            autocomplete="off"
            [formField]="editForm.version"
          />
        </div>

        <div class="ins-admin-form__field">
          <span id="release-edit-month-label">Release month</span>
          <div class="ins-admin-form__row" role="group" aria-labelledby="release-edit-month-label">
            <select
              id="release-edit-month"
              aria-label="Release month"
              [formField]="editForm.releaseMonth"
            >
              @for (month of monthOptions; track month.value) {
                <option [value]="month.value">{{ month.label }}</option>
              }
            </select>
            <select
              id="release-edit-year"
              aria-label="Release year"
              [formField]="editForm.releaseYear"
            >
              @for (year of editYearOptions(); track year) {
                <option [value]="year">{{ year }}</option>
              }
            </select>
          </div>
        </div>

        @if (editForm().touched() && !editFormReady()) {
          <p class="ins-admin-form__hint" role="alert">Enter a version.</p>
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
          <button type="submit" class="ins-admin-action" [disabled]="!editFormReady() || saving()">
            {{ saving() ? 'Saving…' : 'Save changes' }}
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
  protected readonly monthOptions = MONTH_OPTIONS;
  protected readonly releaseModel = signal<ReleaseFormModel>(emptyReleaseModel());
  // Year and month are `<select>`s over a closed list, so neither can be empty or malformed —
  // the validators that guarded the old free-text month input have nothing left to catch.
  protected readonly releaseForm = form(this.releaseModel, (path) => {
    required(path.version, { message: 'Enter a release identifier.' });
    required(path.resourceID, { message: 'Choose a resource.' });
  });
  protected readonly releaseData = resource({ loader: () => this.api.loadReleases() });
  protected readonly releases = computed(() =>
    [...(this.releaseData.value() ?? [])].sort(
      (a, b) => Date.parse(b.releasedAt ?? '') - Date.parse(a.releasedAt ?? ''),
    ),
  );
  protected readonly pagedReleases = computed(() => pageSlice(this.releases(), this.releasePage()));
  protected readonly sortedResources = computed(() =>
    [...this.store.snapshot().resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '')),
  );
  protected readonly resourcesByPlatform = computed(() =>
    groupResourcesByPlatform(this.store.snapshot().resources, this.store.snapshot().accounts),
  );
  protected readonly formReady = computed(() => this.releaseForm().valid());
  protected readonly formatDate = formatAdminDate;
  /** The column is "Release month"; the stored day is an artifact, so do not show one. */
  protected readonly formatMonth = formatAdminMonth;
  protected readonly createYearOptions = computed(() => releaseYearOptions());

  protected readonly editOpen = signal(false);
  protected readonly editingRelease = signal<Release | null>(null);
  protected readonly editModel = signal<ReleaseEditModel>(emptyReleaseEditModel());
  protected readonly editForm = form(this.editModel, (path) => {
    required(path.version, { message: 'Enter a release identifier.' });
  });
  protected readonly editFormReady = computed(() => this.editForm().valid());

  /**
   * The standard range plus whatever year the edited release actually carries.
   *
   * Seeded history predates 2023, and a `<select>` bound to a value with no matching option
   * renders blank — so editing an old release would silently offer to move it into range.
   */
  protected readonly editYearOptions = computed(() =>
    releaseYearOptions(this.editModel().releaseYear),
  );

  protected openEdit(release: Release): void {
    const recorded = toYearMonth(release.releasedAt);
    this.editingRelease.set(release);
    this.editModel.set({
      version: release.version ?? '',
      releaseYear: recorded.year,
      releaseMonth: recorded.month,
    });
    this.formError.set(null);
    this.editOpen.set(true);
  }

  protected closeEdit(): void {
    this.editOpen.set(false);
    this.resetEditForm();
  }

  protected resetEditForm(): void {
    this.editingRelease.set(null);
    this.editModel.set(emptyReleaseEditModel());
    this.formError.set(null);
  }

  protected confirmEdit(event: SubmitEvent): void {
    event.preventDefault();
    this.editForm().markAsTouched();
    const release = this.editingRelease();
    const model = this.editModel();
    const month = { year: Number(model.releaseYear), month: Number(model.releaseMonth) };
    if (!release?.id || !this.editFormReady() || this.saving()) {
      return;
    }

    this.confirmations.confirm({
      target: event.currentTarget as EventTarget,
      header: 'Save changes to this release?',
      message: 'This overwrites the recorded version and release month.',
      rejectLabel: 'Keep editing',
      acceptLabel: 'Save changes',
      acceptButtonProps: { severity: 'warn' },
      rejectButtonProps: { severity: 'secondary', outlined: true },
      accept: () => void this.saveEdit(release, month),
    });
  }

  private async saveEdit(
    release: Release,
    month: { readonly year: number; readonly month: number },
  ): Promise<void> {
    if (!release.id) {
      return;
    }

    const model = this.editModel();
    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.updateRelease(release.id, {
        version: model.version.trim(),
        year: month.year,
        month: month.month,
      });
      this.messages.add({
        severity: 'success',
        summary: 'Release updated',
        detail: `${model.version.trim()} was saved.`,
        life: 3500,
      });
      this.editOpen.set(false);
      this.resetEditForm();
      this.releaseData.reload();
    } catch (error) {
      this.formError.set(toApiError(error));
    } finally {
      this.saving.set(false);
    }
  }

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
    if (!this.formReady() || this.saving()) {
      return;
    }

    this.saving.set(true);
    this.formError.set(null);
    try {
      await this.api.createRelease({
        version: model.version.trim(),
        resourceID: model.resourceID,
        year: Number(model.releaseYear),
        month: Number(model.releaseMonth),
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
  const { year, month } = currentYearMonth();
  return { version: '', resourceID: '', releaseYear: year, releaseMonth: month };
}

function emptyReleaseEditModel(): ReleaseEditModel {
  const { year, month } = currentYearMonth();
  return { version: '', releaseYear: year, releaseMonth: month };
}
