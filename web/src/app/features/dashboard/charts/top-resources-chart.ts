import { Component, computed, inject, input, output } from '@angular/core';
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
 * The ten bars use a dedicated ranked palette. Their hue is deliberately presentational rather
 * than a second encoded dimension: the label inside each bar names the resource and the tooltip
 * states its registry. This gives a single-registry view enough visual rhythm without suggesting
 * that brand colour carries analytical meaning.
 */
@Component({
  selector: 'app-top-resources-chart',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure heading="Who carries the reach" [subtitle]="subtitle()">
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

    return {
      definition: defineChart(
        ({ width }) => {
          const plotWidth = Math.max(1, width - 52);
          const fitsInside = (row: ResourceReading): boolean =>
            (row.value / domainMaximum) * plotWidth >= estimatedLabelWidth(row.name) + 20;

          return {
            marks: [
              barX(rows, {
                id: 'top-resources',
                x: 'value',
                y: 'name',
                color: 'resourceID',
                stroke: palette.surface,
                strokeWidth: 1.5,
                radius: 8,
                maxThickness: 32,
              }),
              decorative(
                text(rows, {
                  id: 'top-resource-names',
                  x: (row: ResourceReading) => (fitsInside(row) ? 0 : row.value),
                  y: 'name',
                  text: 'name',
                  dx: 10,
                  anchor: 'start',
                  fill: (row: ResourceReading) =>
                    fitsInside(row) ? palette.rankedInk : palette.ink,
                  fontSize: 12,
                  fontWeight: 700,
                }),
              ),
              decorative(
                text(rows, {
                  id: 'top-resource-values',
                  x: 'value',
                  y: 'name',
                  text: (row: ResourceReading) => compact(row.value),
                  dx: (row: ResourceReading) =>
                    fitsInside(row) ? 10 : estimatedLabelWidth(row.name) + 20,
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
            color: {
              domain: rows.map((row) => row.resourceID),
              range: rows.map((_, index) => palette.ranked[index % palette.ranked.length]),
            },
            guides: false,
            margin: { top: 5, right: 52, bottom: 5, left: 0 },
          };
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
      // Ten rows need enough room to keep labels and keyboard targets distinct while still
      // fitting inside the one-screen presentation view.
      height: Math.max(300, Math.min(460, rows.length * 46)),
    };
  });
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
