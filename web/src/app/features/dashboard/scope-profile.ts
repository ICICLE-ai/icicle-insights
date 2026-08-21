import { Component, input } from '@angular/core';

export interface ScopeProfileStat {
  readonly label: string;
  readonly value: string;
  readonly context: string;
}

/**
 * A non-chart alternative for scopes whose composition would be a single radial slice.
 *
 * A one-slice donut communicates only "100%" and spends a large visual area doing it. This
 * profile uses the same footprint for four independent catalog facts and a directly labelled
 * coverage measure, all of which remain meaningful for a registry or one resource.
 */
@Component({
  selector: 'app-scope-profile',
  template: `
    <article class="ins-profile" [attr.aria-labelledby]="headingId">
      <header class="ins-profile__header">
        <p class="ins-eyebrow">{{ profileLabel() }}</p>
        <h3 class="ins-profile__title" [id]="headingId">{{ heading() }}</h3>
        <p class="ins-profile__subtitle">{{ subtitle() }}</p>
      </header>

      <dl class="ins-profile__stats">
        @for (stat of stats(); track stat.label) {
          <div class="ins-profile__stat">
            <dt>{{ stat.label }}</dt>
            <dd>{{ stat.value }}</dd>
            <dd class="ins-profile__stat-context">{{ stat.context }}</dd>
          </div>
        }
      </dl>

      <div class="ins-profile__coverage">
        <div class="ins-profile__coverage-copy">
          <span [id]="coverageHeadingId">Measurement coverage</span>
          <strong>{{ coverage() }}%</strong>
        </div>
        <progress
          [value]="coverage()"
          max="100"
          [attr.aria-labelledby]="coverageHeadingId"
          [attr.aria-describedby]="coverageDescriptionId"
        >
          {{ coverage() }}%
        </progress>
        <p [id]="coverageDescriptionId">{{ coverageLabel() }}</p>
      </div>
    </article>
  `,
  styles: `
    :host {
      display: block;
      height: 100%;
    }

    .ins-profile {
      display: flex;
      flex-direction: column;
      gap: 1.25rem;
      box-sizing: border-box;
      height: 100%;
      min-height: 24rem;
      padding: 1.25rem;
      color: var(--ins-ink);
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
    }

    .ins-profile__header {
      display: grid;
      gap: 0.25rem;
    }

    .ins-profile__header p,
    .ins-profile__title {
      margin: 0;
    }

    .ins-profile__title {
      font-size: 1.125rem;
      line-height: 1.25;
    }

    .ins-profile__subtitle {
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-small);
    }

    .ins-profile__stats {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 0.75rem;
      margin: 0;
    }

    .ins-profile__stat {
      display: grid;
      gap: 0.25rem;
      min-width: 0;
      padding: 0.875rem;
      background: var(--ins-raised);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
    }

    .ins-profile__stat dt,
    .ins-profile__stat-context {
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-micro);
    }

    .ins-profile__stat dt {
      font-weight: 650;
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }

    .ins-profile__stat dd {
      margin: 0;
      font-family: var(--ins-font-mono);
      font-size: 1.75rem;
      font-weight: 700;
      line-height: 1.1;
    }

    .ins-profile__stat .ins-profile__stat-context {
      font-family: inherit;
      font-size: var(--ins-text-micro);
      font-weight: 400;
      line-height: inherit;
    }

    .ins-profile__coverage {
      display: grid;
      gap: 0.5rem;
      margin-top: auto;
    }

    .ins-profile__coverage-copy {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 1rem;
      font-size: var(--ins-text-small);
      font-weight: 650;
    }

    .ins-profile__coverage progress {
      width: 100%;
      height: 0.625rem;
      overflow: hidden;
      accent-color: var(--ins-series-1);
      background: var(--ins-grid);
      border: 0;
      border-radius: 999px;
    }

    .ins-profile__coverage progress::-webkit-progress-bar {
      background: var(--ins-grid);
      border-radius: 999px;
    }

    .ins-profile__coverage progress::-webkit-progress-value {
      background: var(--ins-series-1);
      border-radius: 999px;
    }

    .ins-profile__coverage p {
      margin: 0;
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-micro);
    }

    @media (width < 30rem) {
      .ins-profile__stats {
        grid-template-columns: 1fr;
      }
    }
  `,
})
export class ScopeProfile {
  readonly heading = input.required<string>();
  readonly profileLabel = input.required<string>();
  readonly subtitle = input.required<string>();
  readonly stats = input.required<readonly ScopeProfileStat[]>();
  readonly coverage = input.required<number>();
  readonly coverageLabel = input.required<string>();

  protected readonly headingId = 'scope-profile-heading';
  protected readonly coverageHeadingId = 'scope-profile-coverage-heading';
  protected readonly coverageDescriptionId = 'scope-profile-coverage-description';
}
