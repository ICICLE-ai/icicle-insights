import {
  Component,
  DestroyRef,
  ElementRef,
  afterNextRender,
  computed,
  inject,
  input,
  output,
  signal,
} from '@angular/core';
import { defineChart, barX, text, type ChartPoint } from '@tanstack/charts';
import { Chart } from '@tanstack/charts/angular';
import { decorative } from '@tanstack/charts/mark/decorative';
import { scaleBand } from '@tanstack/charts/scales/band';
import { scaleLinear } from '@tanstack/charts/scales/linear';
import { tooltip } from '@tanstack/charts/tooltip';

import type { Platform } from '../../../core/api/models';
import { compact, whole } from '../../../shared/format/formatters';
import { platformLabel } from '../../../shared/format/labels';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { ChartPaletteService } from '../../../shared/charts/chart-palette';

/** One resource and its latest reading for the selected metric. */
export interface ResourceReading {
  readonly resourceID: string;
  readonly name: string;
  readonly platform: Platform;
  readonly value: number;
}

/** How many bars are drawn. The rest of the field lives in the table. */
const TOP_N = 10;

/**
 * The handful of resources carrying a chosen metric.
 *
 * Replaces two earlier attempts, and the reasons are worth keeping. A treemap of all 110
 * resources put the whole field on screen, which sounds better than it reads: past the leading
 * few, the blocks are too small to label or compare, so most of the ink went to things nobody
 * could identify. Before that, a separate chart per metric produced eight panels that had to be
 * scrolled past rather than read.
 *
 * One chart, one metric at a time, ten bars. The metric selector is what makes that
 * sufficient — anything the ten bars exclude is one dropdown or one disclosure away, and the
 * table below carries every resource for the selected metric at exact values.
 *
 * Every bar shares one fill. Colour never encoded anything here — the name identifies the
 * resource and the tooltip states its registry — so a single consistent hue reads as one
 * ranked list rather than implying a relationship between whichever two bars land on the same
 * repeated colour out of a shorter ramp.
 */
@Component({
  selector: 'app-top-resources-chart',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure heading="Which resources lead" [subtitle]="subtitle()">
      <div actions class="ins-top__controls">
        <label class="ins-eyebrow" for="top-metric">Metric</label>
        <select
          id="top-metric"
          class="ins-top__select"
          [value]="metric()"
          (change)="onMetricChange($event)"
        >
          @for (option of metricOptions(); track option.type) {
            <option [value]="option.type">{{ option.label }}</option>
          }
        </select>
      </div>

      <tanstack-chart chart [options]="chartOptions()" />

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          Every resource by
          {{
            metricLabel()
          }}, largest first.
        </caption>
        <thead>
          <tr>
            <th scope="col">Resource</th>
            <th scope="col">Registry</th>
            <th scope="col" class="ins-chart-table__number">{{ metricLabel() }}</th>
          </tr>
        </thead>
        <tbody>
          @for (row of sortedRows(); track row.resourceID) {
            <tr>
              <th scope="row">{{ row.name }}</th>
              <td>{{ registryLabel(row.platform) }}</td>
              <td class="ins-chart-table__number">{{ exact(row.value) }}</td>
            </tr>
          }
        </tbody>
      </table>
    </app-chart-figure>
  `,
  styles: `
    :host {
      display: flex;
      min-height: 0;
    }

    app-chart-figure {
      flex: 1 1 auto;
      min-height: 0;
    }

    .ins-top__controls {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .ins-top__select {
      font: inherit;
      font-size: var(--ins-text-small);
      padding: 0.3125rem 0.5rem;
      color: var(--ins-ink);
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
    }
  `,
})
export class TopResourcesChart {
  readonly rows = input.required<readonly ResourceReading[]>();
  readonly metricOptions = input.required<readonly { type: string; label: string }[]>();
  readonly metric = input.required<string>();
  readonly metricChange = output<string>();

  private readonly paletteService = inject(ChartPaletteService);
  private readonly host: ElementRef<HTMLElement> = inject(ElementRef);
  private readonly destroyRef = inject(DestroyRef);

  protected readonly chartHeight = signal(380);
  protected readonly exact = whole;
  protected readonly registryLabel = platformLabel;

  protected readonly metricLabel = computed(
    () => this.metricOptions().find((o) => o.type === this.metric())?.label ?? this.metric(),
  );

  /** Every resource holding a reading, largest first — the table shows all of them. */
  protected readonly sortedRows = computed(() =>
    [...this.rows()].filter((row) => row.value > 0).sort((a, b) => b.value - a.value),
  );

  /**
   * The drawn bars, largest first.
   *
   * A band scale lays its domain top-to-bottom, so preserving the descending sort puts the
   * highest-ranked resource where reading starts.
   */
  private readonly barRows = computed(() => this.sortedRows().slice(0, TOP_N));

  protected readonly subtitle = computed(() => {
    const all = this.sortedRows();
    const shown = this.barRows();
    const total = all.reduce((sum, row) => sum + row.value, 0);
    const shownTotal = shown.reduce((sum, row) => sum + row.value, 0);

    if (all.length === 0) {
      return `No resource has a ${this.metricLabel().toLowerCase()} reading yet.`;
    }

    const share = total > 0 ? Math.round((shownTotal / total) * 100) : 0;
    // States what the ten bars leave out, so the chart is never mistaken for the whole field.
    return `Top ${shown.length} of ${all.length} resources · ${share}% of ${whole(total)} ${this.metricLabel().toLowerCase()}`;
  });

  protected onMetricChange(event: Event): void {
    this.metricChange.emit((event.target as HTMLSelectElement).value);
  }

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const rows = this.barRows();
    const peak = Math.max(...rows.map((r) => r.value), 0);
    const domainMaximum = niceCeiling(peak * 1.3);
    const accent = palette.ranked[0];
    // Wide enough for the longest visible name, so every label sits in a reserved left margin
    // rather than trailing after its own bar — the same fixed-column treatment the value labels
    // already get on the right, just mirrored, and consistent regardless of bar length.
    const labelMargin = Math.max(60, ...rows.map((row) => estimatedLabelWidth(row.name))) + 24;

    return {
      definition: defineChart(
        {
          marks: [
            barX(rows, {
              id: 'top-resources',
              x: 'value',
              y: 'name',
              fill: accent,
              stroke: palette.surface,
              strokeWidth: 1.5,
              radius: 8,
              maxThickness: 32,
            }),
            decorative(
              text(rows, {
                id: 'top-resource-names',
                x: () => 0,
                y: 'name',
                text: 'name',
                dx: -10,
                anchor: 'end',
                fill: palette.ink,
                fontSize: 12,
                fontWeight: 700,
              }),
            ),
            decorative(
              text(rows, {
                id: 'top-resource-values',
                // A constant, not the row's own value: every value sits in one fixed column
                // at the domain ceiling regardless of bar length, so the ten numbers read down
                // as a straight column rather than trailing each bar at a different offset.
                x: () => domainMaximum,
                y: 'name',
                text: (row: ResourceReading) => compact(row.value),
                dx: 8,
                anchor: 'start',
                fill: palette.ink,
                fontSize: 12,
                fontWeight: 700,
              }),
            ),
          ],
          x: {
            // Pinned to zero so bar length remains proportional. Headroom reserves a clean value
            // column to the right without needing a visible axis or grid.
            scale: scaleLinear().domain([0, domainMaximum]),
            axis: false,
            grid: false,
          },
          y: {
            scale: () => scaleBand<string>().paddingInner(0.2).paddingOuter(0.08),
            axis: false,
          },
          guides: false,
          margin: { top: 5, right: 52, bottom: 5, left: labelMargin },
        },
        {
          focus: 'nearest',
          keyboard: true,
          tooltip: {
            use: tooltip,
            format: (point) => formatResourceTooltip(point, this.metricLabel()),
          },
        },
      ),
      ariaLabel: `Top ${rows.length} resources by ${this.metricLabel()}`,
      ariaDescription: `${this.subtitle()}. Use arrow keys to inspect exact values.`,
      height: this.chartHeight(),
    };
  });

  constructor() {
    afterNextRender(() => {
      if (typeof ResizeObserver === 'undefined') {
        return;
      }

      const observer = new ResizeObserver(() => this.fitChartToViewport());
      observer.observe(this.host.nativeElement);
      this.fitChartToViewport();
      this.destroyRef.onDestroy(() => observer.disconnect());
    });
  }

  /** Uses the open presentation viewport instead of leaving a fixed-height chart in a tall card. */
  private fitChartToViewport(): void {
    const figure = this.host.nativeElement.querySelector<HTMLElement>('.ins-figure');
    const caption = figure?.querySelector<HTMLElement>('.ins-figure__caption');
    const disclosure = figure?.querySelector<HTMLElement>('.ins-figure__data');
    const main = this.host.nativeElement.closest<HTMLElement>('.ins-main');
    const footer = document.querySelector<HTMLElement>('.ins-footer');
    if (!figure || !caption || !disclosure || !main || !footer) {
      return;
    }

    const style = getComputedStyle(figure);
    const mainStyle = getComputedStyle(main);
    const verticalPadding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    const verticalBorder = parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
    const rowGap = parseFloat(style.rowGap || style.gap);
    const chromeHeight =
      verticalPadding +
      caption.getBoundingClientRect().height +
      disclosure.getBoundingClientRect().height +
      rowGap * 2 +
      verticalBorder;
    const hostTop = this.host.nativeElement.getBoundingClientRect().top;
    const contentBottom =
      document.documentElement.clientHeight -
      footer.getBoundingClientRect().height -
      parseFloat(mainStyle.paddingBottom);
    const available = Math.floor(contentBottom - hostTop - chromeHeight);
    const nextHeight = Math.min(960, Math.max(380, available));

    if (nextHeight !== this.chartHeight()) {
      this.chartHeight.set(nextHeight);
    }
  }
}

/** Conservative width estimate for 12px semibold labels in the dashboard's UI font. */
function estimatedLabelWidth(value: string): number {
  return [...value].reduce((width, character) => {
    if (/[MW@#%]/u.test(character)) {
      return width + 9;
    }
    if (/[ilI1|.,'`]/u.test(character)) {
      return width + 4;
    }
    return width + 7;
  }, 0);
}

function isResourceReading(value: unknown): value is ResourceReading {
  return (
    typeof value === 'object' &&
    value !== null &&
    'resourceID' in value &&
    'name' in value &&
    'platform' in value &&
    'value' in value
  );
}

function formatResourceTooltip(point: ChartPoint<unknown>, metric: string): string {
  if (!isResourceReading(point.datum)) {
    return '';
  }

  return `${point.datum.name} · ${platformLabel(point.datum.platform)} · ${whole(point.datum.value)} ${metric.toLowerCase()}`;
}

/**
 * Rounds an axis ceiling up to a readable step.
 *
 * Without it the maximum is whatever the headroom multiplier produced — 1180 rather than 1200 —
 * and every tick inherits that arbitrariness.
 */
function niceCeiling(value: number): number {
  if (!(value > 0)) {
    return 1;
  }

  const magnitude = 10 ** Math.floor(Math.log10(value));
  const step = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].find((s) => value <= s * magnitude) ?? 10;
  return step * magnitude;
}
