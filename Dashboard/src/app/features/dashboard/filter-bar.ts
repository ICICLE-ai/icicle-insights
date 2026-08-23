import { Component, computed, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Select } from '@openng/optimus-ui/select';

import { pluralize } from '../../shared/format/formatters';
import { DashboardStore } from './dashboard-store';

interface Option {
  readonly label: string;
  readonly value: string;
}

/**
 * Narrows the view to one resource.
 *
 * The registry dimension is the analytical dropdown beside this control. What remains here is
 * the filter that genuinely needs search — a list of a hundred-odd resource names, which no rail
 * or short menu could show at once.
 *
 * Accounts are still not offered as a dimension. Every ICICLE account carries the same handle,
 * so the list would read as five identical rows; that dimension is surfaced as the registry it
 * lives on, which is the thing that actually differs.
 */
@Component({
  selector: 'app-filter-bar',
  imports: [FormsModule, Select],
  template: `
    <div class="ins-filters">
      <div class="ins-filters__field">
        <div class="ins-filters__field-heading">
          <label class="ins-eyebrow" for="resource-filter">Resource</label>
          <span class="ins-filters__available ins-mono">{{ availableLabel() }}</span>
        </div>
        <p-select
          inputId="resource-filter"
          [options]="resourceOptions()"
          [ngModel]="store.resourceFilter()"
          (onChange)="store.setResourceFilter($event.value)"
          optionLabel="label"
          optionValue="value"
          [filter]="resourceOptions().length > 8"
          filterBy="label"
          filterPlaceholder="Search resources"
          size="small"
          fluid
          class="ins-filters__select"
        />
      </div>
    </div>
  `,
  styles: `
    .ins-filters {
      display: flex;
      flex-wrap: wrap;
      align-items: stretch;
      gap: 0.75rem;
      height: var(--ins-masthead-height);
      box-sizing: border-box;
      margin: 0;
    }

    .ins-filters__field {
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 0.125rem;
      height: var(--ins-masthead-height);
      box-sizing: border-box;
      min-width: 16rem;
      padding: 0.25rem 0.75rem;
      background: var(--ins-raised);
      border: 1px solid var(--ins-border-strong);
      border-radius: var(--ins-radius);
      transition:
        border-color 120ms ease,
        background 120ms ease;
    }

    .ins-filters__field:hover,
    .ins-filters__field:has(.ins-filters__select.p-focus) {
      background: var(--ins-surface);
      border-color: var(--ins-series-1);
    }

    .ins-filters__field-heading {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 0.75rem;
    }

    .ins-filters__available {
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
      white-space: nowrap;
    }

    /* The analytical card owns the outline. Optimus still owns all combobox behaviour, focus
       semantics and the searchable overlay; its nested root is visually integrated here through
       documented Select design tokens instead of reaching into private markup. */
    .ins-filters__select {
      width: 100%;
      min-height: 2rem;
      --p-select-background: transparent;
      --p-select-border-color: transparent;
      --p-select-hover-border-color: transparent;
      --p-select-focus-border-color: transparent;
      --p-select-shadow: none;
      --p-select-padding-x: 0;
      --p-select-padding-y: 0.125rem;
      --p-select-border-radius: 0;
      --p-select-focus-ring-width: 0;
      --p-select-focus-ring-shadow: none;
    }
  `,
})
export class FilterBar {
  protected readonly store = inject(DashboardStore);

  protected readonly resourceOptions = computed<Option[]>(() => [
    { label: 'All resources', value: 'all' },
    ...this.store
      .selectableResources()
      .map((r) => ({ label: r.name ?? 'Unnamed resource', value: r.id ?? '' })),
  ]);

  protected readonly availableLabel = computed(() =>
    pluralize(this.store.selectableResources().length, 'available resource'),
  );
}
