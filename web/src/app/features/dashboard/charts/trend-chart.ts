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
import {
  areaY,
  crosshair,
  defineChart,
  dot,
  lineY,
  ruleY,
  type ChartPoint,
} from '@tanstack/charts';
import { Chart } from '@tanstack/charts/angular';
import { d3Curve } from '@tanstack/charts/d3/shape';
import { decorative } from '@tanstack/charts/mark/decorative';
import { scaleLinear } from '@tanstack/charts/scales/linear';
import { tooltip } from '@tanstack/charts/tooltip';
import { curveMonotoneX } from 'd3-shape';

import type { SeriesPoint } from '../../../core/analytics/metrics';
import { compact, formatDate, whole } from '../../../shared/format/formatters';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { ChartPaletteService } from '../../../shared/charts/chart-palette';

type TrendRange = 'thirtyDays' | 'sixMonths' | 'year' | 'yearToDate';

interface TrendRangeOption {
  readonly value: TrendRange;
  readonly label: string;
}

export interface TrendMetricOption {
  readonly type: string;
  readonly label: string;
}

export interface TrendSeries extends TrendMetricOption {
  readonly points: readonly SeriesPoint[];
}

interface TrendDatum extends SeriesPoint {
  readonly type: string;
  readonly label: string;
  readonly key: string;
  readonly plotValue: number;
}

type ComparisonCadence = 'daily' | 'weekly' | 'monthly';

interface TrendLegendItem {
  readonly type: string;
  readonly label: string;
  readonly change: number;
  readonly color: string;
}

export const ALL_TREND_METRICS = 'all';

/**
 * Monotone rather than natural cubic interpolation: it smooths the line for presentation without
 * overshooting past a local minimum or maximum, which would draw a dip or spike the data never
 * had. Safe for sparse, noisy count series in a way a natural spline is not.
 */
const smoothCurve = d3Curve(curveMonotoneX);

const RANGE_OPTIONS: readonly TrendRangeOption[] = [
  { value: 'thirtyDays', label: 'Last 30 days' },
  { value: 'sixMonths', label: 'Last 6 months' },
  { value: 'year', label: 'Last year' },
  { value: 'yearToDate', label: 'YTD' },
];

/**
 * How the available metrics have moved, with an optional single-metric inspection mode.
 *
 * A soft area gives the sparse readings continuity, while the line remains the precise boundary.
 * The area is pinned to zero because these are nonnegative counts; a truncated filled baseline
 * would visually exaggerate small changes. Points stay invisible until focus, avoiding the
 * caterpillar effect while giving pointer and keyboard users a precise inspection target.
 */
@Component({
  selector: 'app-trend-chart',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure [heading]="heading()" [subtitle]="subtitle()">
      <div actions class="ins-trend__actions">
        <div class="ins-trend__metric">
          <label class="ins-eyebrow" for="trend-metric">Metric</label>
          <select
            id="trend-metric"
            class="ins-trend__select"
            [value]="metric()"
            (change)="onMetricChange($event)"
          >
            @for (option of metricOptions(); track option.type) {
              <option [value]="option.type">{{ option.label }}</option>
            }
          </select>
        </div>

        <div class="ins-trend__ranges" role="group" [attr.aria-label]="heading() + ' time window'">
          @for (option of rangeOptions; track option.value) {
            <button
              type="button"
              class="ins-trend__range"
              [attr.aria-label]="option.label"
              [attr.aria-pressed]="range() === option.value"
              (click)="setRange(option.value)"
            >
              {{ option.label }}
            </button>
          }
        </div>
      </div>

      <div chart class="ins-trend__visual">
        <tanstack-chart [options]="chartOptions()" />

        @if (isComparison()) {
          <div class="ins-trend__legend" role="group" aria-label="Choose a metric to inspect">
            @for (item of legendItems(); track item.type) {
              <button
                type="button"
                class="ins-trend__legend-item"
                [style.--ins-trend-color]="item.color"
                [attr.aria-label]="
                  'View ' + item.label + ' in detail, ending ' + change(item.change)
                "
                (click)="selectMetric(item.type)"
              >
                <span class="ins-trend__legend-swatch" aria-hidden="true"></span>
                <span class="ins-trend__legend-label">{{ item.label }}</span>
                <strong>{{ change(item.change) }}</strong>
              </button>
            }
          </div>
        }
      </div>

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          {{
            heading()
          }}
          {{
            isComparison()
              ? 'comparison snapshots and change from the first visible value, oldest first.'
              : 'totals at each recorded reading, oldest first.'
          }}
        </caption>
        <thead>
          <tr>
            <th scope="col">{{ isComparison() ? 'Period' : 'Recorded' }}</th>
            @if (isComparison()) {
              <th scope="col">Metric</th>
            }
            <th scope="col" class="ins-chart-table__number">Total</th>
            @if (isComparison()) {
              <th scope="col" class="ins-chart-table__number">Change</th>
            }
          </tr>
        </thead>
        <tbody>
          @for (point of visibleRows(); track point.key) {
            <tr>
              <th scope="row">{{ when(point.time) }}</th>
              @if (isComparison()) {
                <td>{{ point.label }}</td>
              }
              <td class="ins-chart-table__number">{{ exact(point.value) }}</td>
              @if (isComparison()) {
                <td class="ins-chart-table__number">{{ change(point.plotValue) }}</td>
              }
            </tr>
          }
        </tbody>
      </table>
    </app-chart-figure>
  `,
  styles: `
    :host {
      min-height: 0;
    }

    app-chart-figure {
      flex: 1 1 auto;
      min-height: 0;
    }

    .ins-trend__actions,
    .ins-trend__metric {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .ins-trend__actions {
      flex-wrap: wrap;
      justify-content: flex-end;
    }

    .ins-trend__select {
      max-width: 13rem;
      min-height: 2.375rem;
      padding: 0.3125rem 1.75rem 0.3125rem 0.5rem;
      font: inherit;
      font-size: var(--ins-text-small);
      color: var(--ins-ink);
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
    }

    .ins-trend__ranges {
      display: inline-flex;
      gap: 0.125rem;
      padding: 0.1875rem;
      background: var(--ins-raised);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
    }

    .ins-trend__visual {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      min-width: 0;
      min-height: 0;
    }

    .ins-trend__legend {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 0.375rem;
    }

    .ins-trend__legend-item {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr) auto;
      align-items: center;
      gap: 0.5rem;
      min-width: 0;
      min-height: 2.5rem;
      padding: 0.375rem 0.625rem;
      font: inherit;
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-secondary);
      text-align: left;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
      cursor: pointer;
    }

    .ins-trend__legend-item:hover {
      color: var(--ins-ink);
      background: var(--ins-raised);
      border-color: color-mix(in srgb, var(--ins-trend-color) 45%, var(--ins-border));
    }

    .ins-trend__legend-item:focus-visible {
      outline: 3px solid color-mix(in srgb, var(--ins-trend-color) 55%, transparent);
      outline-offset: 1px;
    }

    .ins-trend__legend-swatch {
      width: 0.625rem;
      height: 0.625rem;
      background: var(--ins-trend-color);
      border-radius: 50%;
    }

    .ins-trend__legend-label {
      min-width: 0;
      overflow: hidden;
      font-weight: 650;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .ins-trend__legend-item strong {
      color: var(--ins-ink);
      font-variant-numeric: tabular-nums;
    }

    .ins-trend__range {
      min-width: 3rem;
      min-height: 2rem;
      padding: 0.25rem 0.5rem;
      font: inherit;
      font-size: var(--ins-text-micro);
      font-weight: 700;
      color: var(--ins-ink-muted);
      background: transparent;
      border: 1px solid transparent;
      border-radius: 0.25rem;
      cursor: pointer;
    }

    .ins-trend__range:hover {
      color: var(--ins-ink);
    }

    .ins-trend__range[aria-pressed='true'] {
      color: var(--ins-ink);
      background: var(--ins-surface);
      border-color: var(--ins-border);
      box-shadow: 0 1px 3px rgb(11 15 20 / 10%);
    }

    @media (width < 62rem) {
      .ins-trend__legend {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
    }
  `,
})
export class TrendChart {
  readonly series = input.required<readonly TrendSeries[]>();
  readonly metricOptions = input.required<readonly TrendMetricOption[]>();
  readonly metric = input.required<string>();
  readonly metricChange = output<string>();
  /** Keeps an isolated metric on the same hue it has in the comparison view. */
  readonly slot = input(0);

  private readonly paletteService = inject(ChartPaletteService);
  private readonly host: ElementRef<HTMLElement> = inject(ElementRef);
  private readonly destroyRef = inject(DestroyRef);

  protected readonly rangeOptions = RANGE_OPTIONS;
  protected readonly range = signal<TrendRange>('sixMonths');
  protected readonly chartHeight = signal(260);
  protected readonly exact = whole;
  protected readonly change = formatChange;
  protected readonly when = (time: number) => formatDate(new Date(time).toISOString());

  protected readonly isComparison = computed(() => this.metric() === ALL_TREND_METRICS);

  protected readonly heading = computed(
    () =>
      this.metricOptions().find((option) => option.type === this.metric())?.label ?? 'All metrics',
  );

  private readonly selectedSeries = computed(() =>
    this.isComparison()
      ? this.series()
      : this.series().filter((series) => series.type === this.metric()),
  );

  protected readonly visibleSeries = computed<readonly TrendSeries[]>(() => {
    const series = this.selectedSeries();
    const latest = Math.max(
      ...series.flatMap((item) => item.points.map((point) => point.time)),
      Number.NEGATIVE_INFINITY,
    );
    if (!Number.isFinite(latest)) {
      return [];
    }

    const cutoff = rangeStart(this.range(), latest);
    return series
      .map((item) => ({
        ...item,
        points: item.points.filter((point) => point.time >= cutoff),
      }))
      .filter((item) => item.points.length > 0);
  });

  protected readonly comparisonCadence = computed<ComparisonCadence>(() => {
    const times = this.visibleSeries().flatMap((item) => item.points.map((point) => point.time));
    if (times.length < 2) {
      return 'daily';
    }

    const spanDays = (Math.max(...times) - Math.min(...times)) / (24 * 60 * 60 * 1_000);
    return comparisonCadenceForSpan(spanDays);
  });

  private readonly plottedSeries = computed<readonly TrendSeries[]>(() =>
    this.isComparison()
      ? this.visibleSeries().map((series) => summarizeSeries(series, this.comparisonCadence()))
      : this.visibleSeries(),
  );

  protected readonly visibleRows = computed<readonly TrendDatum[]>(() => {
    const comparison = this.isComparison();
    const rows = this.plottedSeries().flatMap((series) => {
      const baseline = series.points.find((point) => point.value > 0)?.value ?? 1;
      return series.points.map((point) => ({
        ...point,
        type: series.type,
        label: series.label,
        key: `${series.type}-${point.time}`,
        plotValue: comparison ? relativeChange(point.value, baseline) : point.value,
      }));
    });
    return rows.sort((a, b) => a.time - b.time || a.label.localeCompare(b.label));
  });

  protected readonly subtitle = computed(() => {
    const points = this.visibleRows();
    const rawPoints = this.visibleSeries()
      .flatMap((series) => series.points)
      .sort((a, b) => a.time - b.time);
    const span =
      rawPoints.length > 1
        ? ` · ${this.when(rawPoints[0].time)} to ${this.when(rawPoints[rawPoints.length - 1].time)}`
        : '';
    const metricCount = this.visibleSeries().length;
    if (this.isComparison()) {
      return `${metricCount} ${metricCount === 1 ? 'metric' : 'metrics'} · ${this.comparisonCadence()} snapshots · change from first visible reading · ${points.length} plotted values${span}`;
    }
    return `${points.length} ${points.length === 1 ? 'reading' : 'readings'}${span}`;
  });

  protected readonly legendItems = computed<readonly TrendLegendItem[]>(() => {
    const palette = this.paletteService.palette();
    const rows = this.visibleRows();

    return this.plottedSeries().map((series) => {
      const last = [...rows].reverse().find((row) => row.type === series.type);
      const index = this.series().findIndex((candidate) => candidate.type === series.type);

      return {
        type: series.type,
        label: series.label,
        change: last?.plotValue ?? 0,
        color: palette.series[Math.max(0, index) % palette.series.length],
      };
    });
  });

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const series = this.plottedSeries();
    const points = this.visibleRows();
    const comparison = this.isComparison();
    const accent = palette.series[this.slot() % palette.series.length];
    const maximum = Math.max(...points.map((point) => point.plotValue), 0);
    const [yMinimum, yMaximum] = comparison
      ? comparisonExtent(points.map((point) => point.plotValue))
      : [0, niceCeiling(maximum * 1.08)];
    const gradientId = `trend-area-${this.slot()}`;
    const comparisonColors = series.map((item) => {
      const index = this.series().findIndex((candidate) => candidate.type === item.type);
      return palette.series[Math.max(0, index) % palette.series.length];
    });

    return {
      definition: defineChart(
        {
          marks: [
            ...(comparison
              ? [
                  decorative(
                    ruleY([0], {
                      stroke: palette.inkSecondary,
                      strokeOpacity: 0.58,
                      strokeWidth: 1,
                      strokeDasharray: '4 4',
                    }),
                  ),
                ]
              : []),
            ...(comparison
              ? [
                  decorative(
                    lineY(points, {
                      id: 'trend-lines',
                      x: 'time',
                      y: 'plotValue',
                      z: 'label',
                      color: 'label',
                      key: 'key',
                      curve: smoothCurve,
                      strokeWidth: 2.75,
                      strokeOpacity: 0.96,
                    }),
                  ),
                ]
              : [
                  decorative(
                    areaY(points, {
                      id: 'trend-area',
                      x: 'time',
                      y1: 0,
                      y2: 'plotValue',
                      key: 'key',
                      curve: smoothCurve,
                      fill: `url(#${gradientId})`,
                      fillOpacity: 1,
                    }),
                  ),
                  decorative(
                    lineY(points, {
                      id: 'trend-line',
                      x: 'time',
                      y: 'plotValue',
                      key: 'key',
                      curve: smoothCurve,
                      stroke: accent,
                      strokeWidth: 2.75,
                    }),
                  ),
                ]),
            dot(points, {
              id: 'trend-points',
              x: 'time',
              y: 'plotValue',
              z: comparison ? 'label' : undefined,
              color: comparison ? 'label' : undefined,
              key: 'key',
              r: 3,
              fill: comparison ? undefined : accent,
              fillOpacity: 0,
              stroke: palette.surface,
              strokeOpacity: 0,
              strokeWidth: 2,
              states: [
                {
                  when: { focus: 'group' },
                  style: { fillOpacity: 1, strokeOpacity: 1, r: 4.5 },
                },
                {
                  when: { focus: 'primary' },
                  style: { fillOpacity: 1, strokeOpacity: 1, r: 5 },
                },
              ],
            }),
            crosshair<number, number>({
              id: 'trend-crosshair',
              x: {
                stroke: palette.muted,
                strokeOpacity: 0.38,
                strokeWidth: 1,
                strokeDasharray: '3 4',
              },
              y: false,
            }),
          ],
          x: {
            // Epoch milliseconds stay on a linear scale so no undeclared D3 dependency enters
            // the production bundle. These series are sparse enough that explicit tick count is
            // clearer than calendar-aware automatic ticks.
            scale: scaleLinear,
            axis: {
              line: false,
              ticks: {
                count: Math.min(points.length, 5),
                size: 0,
                padding: 8,
                format: this.when,
              },
            },
          },
          y: {
            scale: scaleLinear().domain([yMinimum, yMaximum]),
            grid: true,
            axis: {
              line: false,
              ticks: {
                count: 4,
                size: 0,
                format: (value: number) => (comparison ? formatChange(value) : compact(value)),
              },
            },
          },
          gradients: comparison
            ? []
            : [
                {
                  id: gradientId,
                  x1: 0,
                  y1: 0,
                  x2: 0,
                  y2: 1,
                  stops: [
                    { offset: 0, color: accent, opacity: 0.34 },
                    { offset: 0.58, color: accent, opacity: 0.12 },
                    { offset: 1, color: accent, opacity: 0.015 },
                  ],
                },
              ],
          ...(comparison
            ? {
                color: {
                  domain: series.map((item) => item.label),
                  range: comparisonColors,
                },
              }
            : {}),
          theme: {
            background: 'transparent',
            foreground: palette.inkSecondary,
            muted: palette.muted,
            grid: palette.grid,
            palette: comparison ? comparisonColors : [accent],
          },
          focus: 'group-x',
          focusRing: false,
          maxFocusDistance: Number.POSITIVE_INFINITY,
          tooltip: false,
          keyboard: true,
          clip: true,
          margin: { top: 12, right: 18, bottom: 28, left: comparison ? 58 : 48 },
        },
        {
          keyboard: true,
          tooltip: {
            use: tooltip,
            anchor: comparison ? 'group-center' : 'point',
            placement: ['top', 'right', 'left', 'bottom'],
            offset: 10,
            sort: comparison ? 'color-domain' : 'focus',
            ...(comparison
              ? { formatGroup: (focused) => formatTrendGroup(focused) }
              : { format: (point) => formatTrendTooltip(point, this.heading()) }),
          },
        },
      ),
      ariaLabel: `${this.heading()} over time`,
      ariaDescription: `${this.subtitle()}. Use arrow keys to inspect exact readings.`,
      height: this.chartHeight(),
    };
  });

  constructor() {
    afterNextRender(() => {
      if (typeof ResizeObserver === 'undefined') {
        return;
      }

      const observer = new ResizeObserver(() => {
        this.fitChartToViewport();
      });

      observer.observe(this.host.nativeElement);
      this.destroyRef.onDestroy(() => observer.disconnect());
    });
  }

  protected setRange(range: TrendRange): void {
    this.range.set(range);
  }

  protected onMetricChange(event: Event): void {
    this.metricChange.emit((event.target as HTMLSelectElement).value);
  }

  protected selectMetric(type: string): void {
    this.metricChange.emit(type);
  }

  /** Uses the remaining presentation viewport without depending on the chart's current height. */
  private fitChartToViewport(): void {
    const figure = this.host.nativeElement.querySelector<HTMLElement>('.ins-figure');
    const caption = figure?.querySelector<HTMLElement>('.ins-figure__caption');
    const disclosure = figure?.querySelector<HTMLElement>('.ins-figure__data');
    const legend = figure?.querySelector<HTMLElement>('.ins-trend__legend');
    const visual = figure?.querySelector<HTMLElement>('.ins-trend__visual');
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
    const visualGap = visual ? parseFloat(getComputedStyle(visual).rowGap || '0') : 0;
    const chromeHeight =
      verticalPadding +
      caption.getBoundingClientRect().height +
      disclosure.getBoundingClientRect().height +
      (legend?.getBoundingClientRect().height ?? 0) +
      (legend ? visualGap : 0) +
      rowGap * 2 +
      verticalBorder;
    const hostTop = this.host.nativeElement.getBoundingClientRect().top;
    const contentBottom =
      document.documentElement.clientHeight -
      footer.getBoundingClientRect().height -
      parseFloat(mainStyle.paddingBottom);
    const available = Math.floor(contentBottom - hostTop - chromeHeight);
    const nextHeight = Math.min(
      this.isComparison() ? 520 : 680,
      Math.max(this.isComparison() ? 260 : 320, available),
    );

    if (nextHeight !== this.chartHeight()) {
      this.chartHeight.set(nextHeight);
    }
  }
}

/** Calendar-aware period start, evaluated in UTC to match API timestamps and chart formatting. */
function rangeStart(range: TrendRange, latest: number): number {
  const end = new Date(latest);
  const year = end.getUTCFullYear();
  const month = end.getUTCMonth();

  switch (range) {
    case 'thirtyDays':
      return rollingThirtyDayStart(latest);
    case 'sixMonths':
      return Date.UTC(year, month - 5, 1);
    case 'year': {
      const start = new Date(latest);
      start.setUTCFullYear(year - 1);
      return start.getTime();
    }
    case 'yearToDate':
      return Date.UTC(year, 0, 1);
  }
}

/** Thirty UTC date buckets including the latest date, independent of calendar-month boundaries. */
export function rollingThirtyDayStart(latest: number): number {
  return latest - 29 * 24 * 60 * 60 * 1_000;
}

/** Uses enough temporal detail to show movement without presenting hundreds of noisy crossings. */
export function comparisonCadenceForSpan(spanDays: number): ComparisonCadence {
  if (spanDays <= 45) {
    return 'daily';
  }
  if (spanDays <= 240) {
    return 'weekly';
  }
  return 'monthly';
}

/** Re-bases unlike metric totals to a common zero-percent starting point. */
export function relativeChange(value: number, baseline: number): number {
  return baseline > 0 ? ((value - baseline) / baseline) * 100 : 0;
}

/** Keeps the final portfolio snapshot in each period; individual mode retains every reading. */
function summarizeSeries(series: TrendSeries, cadence: ComparisonCadence): TrendSeries {
  const buckets = new Map<number, SeriesPoint>();
  const ordered = [...series.points].sort((a, b) => a.time - b.time);

  for (const point of ordered) {
    const time = comparisonBucketStart(point.time, cadence);
    buckets.set(time, { time, value: point.value });
  }

  return {
    ...series,
    points: [...buckets.values()].sort((a, b) => a.time - b.time),
  };
}

function comparisonBucketStart(time: number, cadence: ComparisonCadence): number {
  const date = new Date(time);
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth();
  const day = date.getUTCDate();

  if (cadence === 'monthly') {
    return Date.UTC(year, month, 1, 12);
  }
  if (cadence === 'weekly') {
    const daysSinceMonday = (date.getUTCDay() + 6) % 7;
    return Date.UTC(year, month, day - daysSinceMonday, 12);
  }
  return Date.UTC(year, month, day, 12);
}

function isSeriesPoint(value: unknown): value is SeriesPoint {
  return (
    typeof value === 'object' &&
    value !== null &&
    'time' in value &&
    typeof value.time === 'number' &&
    'value' in value &&
    typeof value.value === 'number'
  );
}

function isTrendDatum(value: unknown): value is TrendDatum {
  return (
    isSeriesPoint(value) &&
    'label' in value &&
    typeof value.label === 'string' &&
    'type' in value &&
    typeof value.type === 'string' &&
    'plotValue' in value &&
    typeof value.plotValue === 'number'
  );
}

function formatTrendGroup(points: readonly ChartPoint<unknown>[]): string {
  const rows = points
    .map((point) => point.datum)
    .filter(isTrendDatum)
    .filter(
      (row, index, all) =>
        all.findIndex((candidate) => candidate.type === row.type && candidate.time === row.time) ===
        index,
    );
  const first = rows[0];
  if (!first) {
    return '';
  }

  return [
    formatDate(new Date(first.time).toISOString()),
    ...rows.map(
      (row) => `${row.label}: ${whole(row.value)} total · ${formatChange(row.plotValue)}`,
    ),
  ].join('\n');
}

function formatTrendTooltip(point: ChartPoint<unknown>, heading: string): string {
  if (!isSeriesPoint(point.datum)) {
    return '';
  }

  return `${formatDate(new Date(point.datum.time).toISOString())} · ${whole(point.datum.value)} ${heading.toLowerCase()}`;
}

function niceCeiling(value: number): number {
  if (!(value > 0)) {
    return 1;
  }

  const magnitude = 10 ** Math.floor(Math.log10(value));
  const step = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].find(
    (candidate) => value <= candidate * magnitude,
  );
  return (step ?? 10) * magnitude;
}

function comparisonExtent(values: readonly number[]): readonly [number, number] {
  if (values.length === 0) {
    return [0, 1];
  }

  const minimum = Math.min(0, ...values);
  const maximum = Math.max(0, ...values);
  const span = Math.max(maximum - minimum, 1);
  const lower = minimum < 0 ? -niceCeiling(Math.abs(minimum - span * 0.08)) : 0;
  const upper = maximum > 0 ? niceCeiling(maximum + span * 0.08) : 0;

  return lower === upper ? [lower, lower + 1] : [lower, upper];
}

function formatChange(value: number): string {
  const rounded = Math.round(value);
  return `${rounded > 0 ? '+' : ''}${whole(rounded)}%`;
}
