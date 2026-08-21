import { Component, ElementRef, inject, signal, viewChild } from '@angular/core';
import { DialogModule } from '@openng/optimus-ui/dialog';

import { ExperimentStore, type AdminOverviewVariant } from '../../core/layout/experiment-store';

interface ExperimentOption {
  readonly value: AdminOverviewVariant;
  readonly label: string;
  readonly hint: string;
}

const ADMIN_OVERVIEW_OPTIONS: readonly ExperimentOption[] = [
  {
    value: 'status-first',
    label: 'Status first',
    hint: 'Lead with four health ratios, then show the prioritized work queue.',
  },
  {
    value: 'triage-first',
    label: 'Triage first',
    hint: 'Lead with the work queue, then place health ratios underneath it.',
  },
];

/** A development-only choice that can be promoted and removed once the admin view is reviewed. */
@Component({
  selector: 'app-experiment-picker',
  imports: [DialogModule],
  template: `
    <button
      #trigger
      type="button"
      class="ins-experiment-trigger"
      aria-haspopup="dialog"
      aria-controls="experiment-options-dialog"
      [attr.aria-expanded]="isDialogOpen()"
      (click)="isDialogOpen.set(true)"
    >
      <span aria-hidden="true">⇄</span>
      <span>Admin overview</span>
    </button>

    <p-dialog
      id="experiment-options-dialog"
      header="Admin overview comparison"
      closeAriaLabel="Close admin overview comparison"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [visible]="isDialogOpen()"
      (visibleChange)="isDialogOpen.set($event)"
      (onHide)="restoreFocus()"
    >
      <p class="ins-experiment-intro">
        Both options use the same operational snapshot. This changes only the reading order.
      </p>

      <fieldset class="ins-experiment-options">
        <legend class="ins-visually-hidden">Choose the admin overview reading order</legend>
        @for (option of options; track option.value) {
          <label
            class="ins-experiment-option"
            [class.is-selected]="experiments.adminOverview() === option.value"
          >
            <input
              type="radio"
              name="admin-overview-variant"
              [checked]="experiments.adminOverview() === option.value"
              (change)="experiments.setAdminOverview(option.value)"
            />
            <span>
              <strong>{{ option.label }}</strong>
              <small>{{ option.hint }}</small>
            </span>
          </label>
        }
      </fieldset>
    </p-dialog>
  `,
  styles: `
    .ins-experiment-trigger {
      display: inline-flex;
      align-items: center;
      gap: 0.375rem;
      min-height: 2.25rem;
      padding: 0.375rem 0.625rem;
      color: var(--ins-ink-secondary);
      background: transparent;
      border: 1px solid transparent;
      border-radius: var(--ins-radius-sm);
      font: inherit;
      font-size: var(--ins-text-small);
      font-weight: 600;
      cursor: pointer;
      white-space: nowrap;
    }

    .ins-experiment-trigger:hover,
    .ins-experiment-trigger[aria-expanded='true'] {
      color: var(--ins-ink);
      background: var(--ins-raised);
      border-color: var(--ins-border);
    }

    .ins-experiment-intro {
      margin: 0 0 1rem;
      color: var(--ins-ink-secondary);
      font-size: var(--ins-text-small);
    }

    .ins-experiment-options {
      display: grid;
      gap: 0.625rem;
      margin: 0;
      padding: 0;
      border: 0;
    }

    .ins-experiment-option {
      position: relative;
      display: grid;
      padding: 0.875rem;
      color: var(--ins-ink-secondary);
      background: var(--ins-plane);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
      cursor: pointer;
    }

    .ins-experiment-option.is-selected {
      color: var(--ins-ink);
      background: var(--ins-surface);
      border-color: var(--ins-series-1);
      box-shadow: inset 3px 0 0 var(--ins-series-1);
    }

    .ins-experiment-option input {
      position: absolute;
      width: 1px;
      height: 1px;
      opacity: 0;
    }

    .ins-experiment-option:has(input:focus-visible) {
      outline: 2px solid var(--ins-series-1);
      outline-offset: 2px;
    }

    .ins-experiment-option span {
      display: grid;
      gap: 0.25rem;
    }

    .ins-experiment-option strong {
      color: var(--ins-ink);
      font-size: var(--ins-text-small);
    }

    .ins-experiment-option small {
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-small);
      line-height: 1.45;
    }
  `,
})
export class ExperimentPicker {
  protected readonly experiments = inject(ExperimentStore);
  protected readonly options = ADMIN_OVERVIEW_OPTIONS;
  protected readonly isDialogOpen = signal(false);
  protected readonly dialogStyle = { width: '30rem', maxWidth: 'calc(100vw - 2rem)' };

  private readonly trigger = viewChild<ElementRef<HTMLButtonElement>>('trigger');

  protected restoreFocus(): void {
    this.trigger()?.nativeElement.focus();
  }
}
