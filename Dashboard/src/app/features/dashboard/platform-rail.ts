import { Component, computed, inject } from '@angular/core';

import type { Platform } from '../../core/api/models';
import { whole } from '../../shared/format/formatters';
import { platformColor, platformLabel } from '../../shared/format/labels';
import { DashboardStore } from './dashboard-store';

/** One cell of the rail. `platform` is null for the "all platforms" cell. */
interface RailCell {
  readonly platform: Platform | null;
  readonly label: string;
  readonly count: number;
  /** Bar width as a percentage of the largest cell. */
  readonly share: number;
  readonly color: string;
}

/**
 * The registry rail: how the catalog is distributed, and the control that scopes it.
 *
 * This replaces a plain dropdown. A dropdown listing five registry names showed nothing about
 * them — you had to select one to discover it held four resources — so the most important
 * structural fact about the catalog, that it is spread unevenly across five registries, was
 * invisible until you went looking. Here the control *is* the view: each cell carries its own
 * count and a bar, so the distribution is legible before anyone interacts, and choosing a scope
 * is the same gesture as reading it.
 *
 * Built on native radios for the same reason as the theme picker: this is a single-choice group,
 * and radios supply arrow-key navigation, roving focus and group semantics that a div-based
 * control has to reimplement and rarely gets right.
 *
 * Bars are scaled against the largest cell rather than the total. Both are honest — the baseline
 * is zero either way — but against the total the four-resource registries would render as a
 * sliver indistinguishable from empty, and the exact count sits beside every bar regardless.
 */
@Component({
  selector: 'app-platform-rail',
  template: `
    <fieldset class="ins-rail">
      <legend class="ins-eyebrow ins-rail__legend">Registry</legend>

      <div class="ins-rail__cells">
        @for (cell of cells(); track cell.label) {
          <label class="ins-rail__cell" [class.is-selected]="isSelected(cell)">
            <input
              class="ins-rail__input"
              type="radio"
              name="platform"
              [checked]="isSelected(cell)"
              (change)="select(cell)"
            />

            <span class="ins-rail__name">{{ cell.label }}</span>

            <!-- The bar is decorative: the count beside it carries the same value in text, so
                 announcing it would repeat the number for no gain. -->
            <span class="ins-rail__track" aria-hidden="true">
              <span
                class="ins-rail__bar"
                [style.width.%]="cell.share"
                [style.background]="cell.color"
              ></span>
            </span>

            <span class="ins-rail__count ins-mono">{{ count(cell.count) }}</span>
            <span class="ins-visually-hidden">
              {{ cell.label }}, {{ count(cell.count) }} resources
            </span>
          </label>
        }
      </div>
    </fieldset>
  `,
  styles: `
    .ins-rail {
      margin: 0 0 1.25rem;
      padding: 0;
      border: 0;
    }

    .ins-rail__legend {
      padding: 0;
      margin-bottom: 0.5rem;
    }

    .ins-rail__cells {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(8.5rem, 1fr));
      gap: 0.5rem;
    }

    .ins-rail__cell {
      display: grid;
      grid-template-rows: auto auto auto;
      gap: 0.5rem;
      padding: 0.75rem 0.875rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
      cursor: pointer;
      /* Colour alone never marks selection; the border weight and ink do it too, so the state
         survives a colour-vision difference and forced-colors mode. */
      transition:
        border-color 120ms ease,
        background 120ms ease;
    }

    .ins-rail__cell:hover {
      border-color: var(--ins-border-strong);
    }

    .ins-rail__cell.is-selected {
      border-color: var(--ins-ink);
      background: var(--ins-raised);
    }

    .ins-rail__input {
      position: absolute;
      width: 1px;
      height: 1px;
      opacity: 0;
      pointer-events: none;
    }

    .ins-rail__input:focus-visible + .ins-rail__name {
      outline: 2px solid var(--ins-series-1);
      outline-offset: 3px;
      border-radius: 2px;
    }

    .ins-rail__name {
      font-size: var(--ins-text-small);
      font-weight: 500;
      color: var(--ins-ink-secondary);
    }

    .ins-rail__cell.is-selected .ins-rail__name {
      color: var(--ins-ink);
    }

    .ins-rail__track {
      display: block;
      height: 4px;
      background: var(--ins-grid);
      border-radius: 2px;
      overflow: hidden;
    }

    .ins-rail__bar {
      display: block;
      height: 100%;
      border-radius: 2px;
    }

    .ins-rail__count {
      font-size: var(--ins-text-lead);
      font-weight: 600;
      color: var(--ins-ink);
      line-height: 1;
    }
  `,
})
export class PlatformRail {
  private readonly store = inject(DashboardStore);

  protected readonly count = whole;

  protected readonly cells = computed<RailCell[]>(() => {
    const counts = this.store.platformCounts();
    const total = counts.reduce((sum, entry) => sum + entry.count, 0);
    const largest = Math.max(...counts.map((entry) => entry.count), 1);

    return [
      {
        platform: null,
        label: 'Overview',
        count: total,
        share: 100,
        // Neutral, because "all" is not one of the categories the palette names — giving it a
        // series colour would imply it were a sixth registry.
        color: 'var(--ins-ink-muted)',
      },
      ...counts.map((entry) => ({
        platform: entry.platform,
        label: platformLabel(entry.platform),
        count: entry.count,
        share: (entry.count / largest) * 100,
        // Slot follows the canonical ordering, so a registry keeps its colour no matter which
        // others are present or what the counts happen to be.
        color: platformColor(entry.platform),
      })),
    ];
  });

  protected isSelected(cell: RailCell): boolean {
    return this.store.platformFilter() === (cell.platform ?? 'all');
  }

  protected select(cell: RailCell): void {
    this.store.setPlatformFilter(cell.platform ?? 'all');
  }
}
