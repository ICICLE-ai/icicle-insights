import { Component, computed, input } from '@angular/core';

import { compact, whole } from '../format/formatters';

/**
 * A single headline figure with its label and the context that makes it meaningful.
 *
 * The displayed value is abbreviated, which loses precision — so the exact figure rides along in
 * the accessible name and in a native `title`. Without that, "1.2M" is the only form of the
 * number anyone can obtain from this tile, and a stat tile that cannot be read exactly is a
 * decoration.
 */
@Component({
  selector: 'app-stat-tile',
  template: `
    <div class="ins-tile">
      <p class="ins-tile__label">{{ label() }}</p>
      <p class="ins-tile__value" [title]="exact()">
        <span aria-hidden="true">{{ display() }}</span>
        <span class="ins-visually-hidden">{{ exact() }}</span>
      </p>
      <p class="ins-tile__context">{{ context() }}</p>
    </div>
  `,
  styles: `
    .ins-tile {
      display: flex;
      flex-direction: column;
      justify-content: center;
      gap: 0.375rem;
      padding: 1.125rem 1.25rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
      height: 100%;
    }

    .ins-tile__label {
      margin: 0;
      font-size: var(--ins-text-small);
      font-weight: 500;
      color: var(--ins-ink-secondary);
    }

    /* The figure wears the mono face, like every other measured value on the page. Tabular
       figures matter here beyond alignment: without them a refresh that changes 9 to 1 visibly
       reflows the number's width. */
    .ins-tile__value {
      margin: 0;
      font-family: var(--ins-font-mono);
      font-variant-numeric: tabular-nums;
      font-size: var(--ins-text-figure);
      font-weight: 600;
      line-height: 1.05;
      letter-spacing: -0.02em;
      color: var(--ins-ink);
    }

    .ins-tile__context {
      margin: 0;
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
    }
  `,
})
export class StatTile {
  readonly label = input.required<string>();
  readonly value = input.required<number>();
  readonly context = input('');

  protected readonly display = computed(() => compact(this.value()));
  protected readonly exact = computed(() => whole(this.value()));
}
