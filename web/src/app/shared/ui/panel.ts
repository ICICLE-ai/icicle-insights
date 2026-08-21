import { Component, input } from '@angular/core';

/**
 * A titled card.
 *
 * The heading is a real `h2`, not styled text: panels are the second level of this page's
 * outline, and a screen-reader user navigating by heading is how they skim the dashboard.
 * `subtitle` is where the window a figure covers gets stated — "30 days", "top 8 shown" — which
 * is the difference between a number that is honest and one that merely looks precise.
 */
@Component({
  selector: 'app-panel',
  template: `
    <section class="ins-panel">
      <div class="ins-panel__head">
        <h2 class="ins-panel__title">{{ heading() }}</h2>
        @if (subtitle()) {
          <p class="ins-panel__subtitle">{{ subtitle() }}</p>
        }
      </div>
      <ng-content />
    </section>
  `,
  styles: `
    .ins-panel {
      display: flex;
      flex-direction: column;
      gap: 1rem;
      padding: 1.25rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: 0.75rem;
      height: 100%;
    }

    .ins-panel__head {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }

    .ins-panel__title {
      margin: 0;
      font-size: 0.9375rem;
      font-weight: 650;
      color: var(--ins-ink);
    }

    .ins-panel__subtitle {
      margin: 0;
      font-size: 0.8125rem;
      color: var(--ins-ink-muted);
    }
  `,
})
export class Panel {
  readonly heading = input.required<string>();
  readonly subtitle = input<string>();
}
