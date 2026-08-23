import { Component, computed, input, model } from '@angular/core';

/** Rows per page unless a table says otherwise. */
export const DEFAULT_PAGE_SIZE = 10;

/**
 * The rows belonging on `page`, clamped to the last page that exists.
 *
 * Lives beside `Paginator` because the two must clamp identically: the component decides which
 * page *number* to show and this decides which rows go with it, and a table whose slice
 * disagreed with its own pager would report "Page 2 of 1" over an empty body. Every paged table
 * in the app calls this rather than repeating the arithmetic.
 *
 * Clamping rather than returning empty is what makes a shrinking list safe — filter a table
 * while parked on page 5 and it lands on the new last page instead of on nothing.
 */
export function pageSlice<T>(
  items: readonly T[],
  page: number,
  pageSize: number = DEFAULT_PAGE_SIZE,
): readonly T[] {
  const lastPage = Math.max(0, Math.ceil(items.length / pageSize) - 1);
  const current = Math.min(Math.max(0, page), lastPage);
  return items.slice(current * pageSize, current * pageSize + pageSize);
}

/** Compact, keyboard-native paging for any record table in the app. */
@Component({
  selector: 'app-paginator',
  template: `
    @if (total() > pageSize()) {
      <nav class="ins-admin-pager" [attr.aria-label]="label() + ' pages'">
        <p class="ins-admin-pager__summary" aria-live="polite">
          {{ start() }}–{{ end() }} of {{ total() }} · Page {{ currentPage() + 1 }} of
          {{ totalPages() }}
        </p>
        <div class="ins-admin-pager__actions">
          <button type="button" [disabled]="currentPage() === 0" (click)="previous()">
            <span aria-hidden="true">←</span> Previous
          </button>
          <button type="button" [disabled]="currentPage() >= totalPages() - 1" (click)="next()">
            Next <span aria-hidden="true">→</span>
          </button>
        </div>
      </nav>
    }
  `,
  styles: `
    :host {
      display: block;
    }

    .ins-admin-pager {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      min-height: 3.5rem;
      padding: 0.625rem 0.75rem;
      border-top: 1px solid var(--ins-border);
    }

    .ins-admin-pager__summary {
      margin: 0;
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-small);
      font-variant-numeric: tabular-nums;
    }

    .ins-admin-pager__actions {
      display: flex;
      gap: 0.375rem;
    }

    button {
      min-height: 2.25rem;
      padding: 0.375rem 0.75rem;
      color: var(--ins-ink-secondary);
      background: var(--ins-raised);
      border: 1px solid var(--ins-border-strong);
      border-radius: var(--ins-radius-sm);
      font: inherit;
      font-size: var(--ins-text-small);
      font-weight: 650;
      cursor: pointer;
    }

    button:hover:not(:disabled) {
      color: var(--ins-ink);
      border-color: var(--ins-series-1);
    }

    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    @media (width < 36rem) {
      .ins-admin-pager {
        align-items: stretch;
        flex-direction: column;
      }

      .ins-admin-pager__actions,
      button {
        flex: 1;
      }
    }
  `,
})
export class Paginator {
  readonly total = input.required<number>();
  readonly label = input.required<string>();
  readonly pageSize = input(DEFAULT_PAGE_SIZE);
  readonly page = model(0);

  protected readonly totalPages = computed(() =>
    Math.max(1, Math.ceil(this.total() / this.pageSize())),
  );
  protected readonly currentPage = computed(() =>
    Math.min(Math.max(0, this.page()), this.totalPages() - 1),
  );
  protected readonly start = computed(() => this.currentPage() * this.pageSize() + 1);
  protected readonly end = computed(() =>
    Math.min(this.total(), (this.currentPage() + 1) * this.pageSize()),
  );

  protected previous(): void {
    this.page.set(Math.max(0, this.currentPage() - 1));
  }

  protected next(): void {
    this.page.set(Math.min(this.totalPages() - 1, this.currentPage() + 1));
  }
}
