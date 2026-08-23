import { Component, input } from '@angular/core';

/**
 * A chart with its heading, its context line, and its data table.
 *
 * The table slot is not optional by convention — it is structural, because two separate rules
 * both demand it. The library's own accessibility guidance says a chart needs a text or table
 * alternative wherever exact values matter, and the palette's light-mode steps for aqua, yellow
 * and magenta sit under 3:1 against the surface, whose documented mitigation is visible labels
 * or a table view. Building the table into the wrapper means a chart cannot ship without one by
 * being forgotten.
 *
 * It is collapsed by default so the page stays scannable. `<details>` is keyboard operable and
 * announced as expandable natively, so nothing is lost by collapsing it.
 */
@Component({
  selector: 'app-chart-figure',
  template: `
    <figure class="ins-figure">
      <figcaption class="ins-figure__caption">
        <div class="ins-figure__caption-copy">
          <h3 class="ins-figure__title">{{ heading() }}</h3>
          @if (subtitle()) {
            <p class="ins-figure__subtitle">{{ subtitle() }}</p>
          }
        </div>

        <ng-content select="[actions]" />
      </figcaption>

      <div class="ins-figure__chart">
        <ng-content select="[chart]" />
      </div>

      <details class="ins-figure__data">
        <summary>
          <span class="ins-figure__show-label">Show data table</span>
          <span class="ins-figure__hide-label">Hide data table</span>
        </summary>
        <div class="ins-figure__table">
          <ng-content select="[table]" />
        </div>
      </details>
    </figure>
  `,
  styles: `
    /* Fills its grid cell so two figures placed side by side end on the same line, whatever
       their chart heights or how far their subtitles wrap. Without it the shorter card stops
       early and the row reads as broken rather than paired. */
    :host {
      display: block;
      height: 100%;
    }

    .ins-figure {
      position: relative;
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      height: 100%;
      margin: 0;
      padding: 1.25rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
    }

    .ins-figure__caption {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: start;
      gap: 0.75rem 1rem;
    }

    .ins-figure__caption-copy {
      display: grid;
      gap: 0.25rem;
      min-width: 0;
    }

    .ins-figure__title {
      margin: 0;
      font-size: 0.9375rem;
      font-weight: 650;
      color: var(--ins-ink);
    }

    .ins-figure__subtitle {
      margin: 0;
      font-size: var(--ins-text-small);
      color: var(--ins-ink-muted);
    }

    /* The chart sizes to this container; without a min-width the flex column can collapse it to
       zero on a narrow viewport and the chart renders as an empty strip. Growing to fill the
       slack in a stretched card is what keeps the disclosure below aligned across a
       side-by-side pair. */
    .ins-figure__chart {
      display: flex;
      flex-direction: column;
      justify-content: center;
      min-width: 0;
      flex: 1;
    }

    /* Pinned to the bottom edge, so paired cards show their disclosure on the same line rather
       than wherever each chart happened to end. */
    .ins-figure__data {
      margin-top: auto;
    }

    .ins-figure__data > summary {
      /* 44px target for the disclosure control. */
      padding: 0.625rem 0;
      font-size: 0.8125rem;
      color: var(--ins-ink-secondary);
      cursor: pointer;
    }

    .ins-figure__hide-label,
    .ins-figure__data[open] .ins-figure__show-label {
      display: none;
    }

    .ins-figure__data[open] .ins-figure__hide-label {
      display: inline;
    }

    .ins-figure__table {
      overflow-x: auto;
      max-height: 20rem;
      overflow-y: auto;
    }

    /* The dashboard is a one-screen presentation surface. Its table disclosure swaps an exact
       data view into the chart body instead of lengthening the document; large tables scroll
       inside that bounded view. */
    :host-context(app-dashboard) .ins-figure__data[open] .ins-figure__table {
      position: absolute;
      z-index: 2;
      inset: 5rem 1.25rem 4.25rem;
      max-height: none;
      padding: 0.5rem;
      overflow: auto;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
      box-shadow: 0 0.5rem 1.5rem rgb(11 15 20 / 8%);
    }

    @media (width < 40rem) {
      .ins-figure__caption {
        grid-template-columns: 1fr;
      }
    }
  `,
})
export class ChartFigure {
  readonly heading = input.required<string>();
  readonly subtitle = input<string>();
}
