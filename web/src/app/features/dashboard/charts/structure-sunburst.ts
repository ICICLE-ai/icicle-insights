import { Component, computed, inject, input, linkedSignal } from '@angular/core';
import { defineChart, type ChartPoint } from '@tanstack/charts';
import { Chart } from '@tanstack/charts/angular';
import { decorative } from '@tanstack/charts/mark/decorative';
import { pie, polar, radialArc, radialText, type PieDatum } from '@tanstack/charts/polar';
import { scaleLinear } from '@tanstack/charts/scales/linear';
import { tooltip } from '@tanstack/charts/tooltip';

import type { Platform, ResourceType } from '../../../core/api/models';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { ChartPaletteService } from '../../../shared/charts/chart-palette';
import { whole } from '../../../shared/format/formatters';
import {
  RESOURCE_TYPE_ORDER,
  platformLabel,
  resourceTypeLabel,
} from '../../../shared/format/labels';

/** How many resources of one type live on one registry. */
export interface StructureRow {
  readonly type: ResourceType;
  readonly platform: Platform;
  readonly count: number;
}

interface TypeSummary {
  readonly type: ResourceType;
  readonly label: string;
  readonly pluralLabel: string;
  readonly count: number;
}

interface CenterRow {
  readonly id: string;
  readonly angle: number;
  readonly radius: number;
  readonly text: string;
  readonly dy: number;
}

type TypeArc = PieDatum<TypeSummary>;

const TAU = Math.PI * 2;
const GAP_ANGLE = (Math.PI / 180) * 3;

const TYPE_PLURALS: Readonly<Record<ResourceType, string>> = {
  container: 'Containers',
  dataset: 'Datasets',
  model: 'Models',
  package: 'Packages',
  repository: 'Repositories',
  service: 'Services',
};

const PERCENT = new Intl.NumberFormat('en-US', {
  style: 'percent',
  maximumFractionDigits: 1,
});

/**
 * A rounded donut showing the portfolio's resource-type composition.
 *
 * This intentionally replaces the former two-ring sunburst. Registry already has a dedicated,
 * directly comparable rail; repeating it as a second radial ring made the chart harder to read.
 * One ring answers one question cleanly: what kinds of resources does the institute publish?
 */
@Component({
  selector: 'app-structure-sunburst',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure heading="What the institute publishes" [subtitle]="subtitle()">
      <div chart class="ins-donut-layout">
        <tanstack-chart [options]="chartOptions()" />

        <div class="ins-donut-legend" role="group" aria-label="Select a resource type">
          @for (row of typeSummaries(); track row.type; let i = $index) {
            <button
              type="button"
              class="ins-donut-legend__item"
              [class.is-selected]="activeType() === row.type"
              [attr.aria-pressed]="activeType() === row.type"
              (click)="selectType(row.type)"
            >
              <span
                class="ins-donut-legend__swatch"
                [style.background]="typeColor(row.type)"
                aria-hidden="true"
              ></span>
              <span class="ins-donut-legend__label">{{ row.pluralLabel }}</span>
              <span class="ins-donut-legend__value ins-mono">{{ exact(row.count) }}</span>
              <span class="ins-donut-legend__share ins-mono">{{ share(row.count) }}</span>
            </button>
          }
        </div>
      </div>

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          Resource counts by type and registry.
        </caption>
        <thead>
          <tr>
            <th scope="col">Type</th>
            <th scope="col">Registry</th>
            <th scope="col" class="ins-chart-table__number">Resources</th>
          </tr>
        </thead>
        <tbody>
          @for (row of sortedRows(); track row.type + row.platform) {
            <tr>
              <th scope="row">{{ typeLabel(row.type) }}</th>
              <td>{{ registryLabel(row.platform) }}</td>
              <td class="ins-chart-table__number">{{ exact(row.count) }}</td>
            </tr>
          }
        </tbody>
      </table>
    </app-chart-figure>
  `,
  styles: `
    .ins-donut-layout {
      display: grid;
      grid-template-columns: minmax(17rem, 1fr) minmax(12rem, 15rem);
      align-items: center;
      gap: 1rem;
      min-width: 0;
    }

    .ins-donut-layout tanstack-chart {
      min-width: 0;
    }

    .ins-donut-legend {
      display: grid;
      gap: 0.25rem;
    }

    .ins-donut-legend__item {
      display: grid;
      grid-template-columns: 0.625rem minmax(0, 1fr) auto auto;
      align-items: center;
      gap: 0.625rem;
      min-height: 2.5rem;
      padding: 0.4375rem 0.625rem;
      font: inherit;
      color: var(--ins-ink-secondary);
      background: transparent;
      border: 1px solid transparent;
      border-radius: var(--ins-radius-sm);
      cursor: pointer;
      text-align: left;
    }

    .ins-donut-legend__item:hover {
      color: var(--ins-ink);
      background: var(--ins-raised);
    }

    .ins-donut-legend__item.is-selected {
      color: var(--ins-ink);
      background: var(--ins-raised);
      border-color: var(--ins-border);
    }

    .ins-donut-legend__swatch {
      width: 0.5625rem;
      height: 0.5625rem;
      border-radius: 999px;
    }

    .ins-donut-legend__label {
      overflow: hidden;
      font-size: var(--ins-text-small);
      font-weight: 600;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .ins-donut-legend__value,
    .ins-donut-legend__share {
      font-size: var(--ins-text-small);
      font-variant-numeric: tabular-nums;
    }

    .ins-donut-legend__share {
      min-width: 2.75rem;
      color: var(--ins-ink-muted);
      text-align: right;
    }

    @media (width < 46rem) {
      .ins-donut-layout {
        grid-template-columns: 1fr;
      }

      .ins-donut-legend {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
    }

    @media (width < 30rem) {
      .ins-donut-legend {
        grid-template-columns: 1fr;
      }
    }
  `,
})
export class StructureSunburst {
  readonly rows = input.required<readonly StructureRow[]>();

  private readonly paletteService = inject(ChartPaletteService);

  protected readonly exact = whole;
  protected readonly typeLabel = resourceTypeLabel;
  protected readonly registryLabel = platformLabel;

  protected readonly sortedRows = computed(() =>
    [...this.rows()].sort(
      (a, b) => b.count - a.count || a.type.localeCompare(b.type),
    ),
  );

  protected readonly typeSummaries = computed<readonly TypeSummary[]>(() => {
    const totals = new Map<ResourceType, number>();
    for (const row of this.rows()) {
      totals.set(row.type, (totals.get(row.type) ?? 0) + row.count);
    }

    return RESOURCE_TYPE_ORDER.filter((type) => totals.has(type))
      .map((type) => ({
        type,
        label: resourceTypeLabel(type),
        pluralLabel: TYPE_PLURALS[type],
        count: totals.get(type) ?? 0,
      }))
      .sort(
        (a, b) =>
          b.count - a.count
          || RESOURCE_TYPE_ORDER.indexOf(a.type) - RESOURCE_TYPE_ORDER.indexOf(b.type),
      );
  });

  protected readonly activeType = linkedSignal<readonly TypeSummary[], ResourceType | null>({
    source: this.typeSummaries,
    computation: (rows, previous) => {
      const previousType = previous?.value;
      return previousType && rows.some((row) => row.type === previousType)
        ? previousType
        : (rows[0]?.type ?? null);
    },
  });

  private readonly activeSummary = computed(
    () => this.typeSummaries().find((row) => row.type === this.activeType()) ?? null,
  );

  private readonly total = computed(() =>
    this.typeSummaries().reduce((sum, row) => sum + row.count, 0),
  );

  protected readonly subtitle = computed(() => {
    const active = this.activeSummary();
    const base = `${whole(this.total())} resources across ${this.typeSummaries().length} kinds`;
    return active
      ? `${base} · ${active.pluralLabel} account for ${this.share(active.count)}`
      : base;
  });

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const rows = this.typeSummaries();
    const active = this.activeSummary();
    const arcs = pie(rows, { value: 'count', gapAngle: GAP_ANGLE });
    const centerRows: readonly CenterRow[] = active
      ? [
          { id: 'active-label', angle: 0, radius: 0, text: active.pluralLabel, dy: -10 },
          { id: 'active-value', angle: 0, radius: 0, text: whole(active.count), dy: 15 },
        ]
      : [];

    const definition = defineChart(
      {
        marks: [
          polar({
            id: 'resource-type-donut',
            radiusRatio: 0.78,
            marks: [
              radialArc(arcs, {
                id: 'resource-type-slices',
                key: 'type',
                color: 'type',
                innerRadius: ({ radius }) => radius * 0.58,
                cornerRadius: 8,
                stroke: palette.surface,
                strokeWidth: 1.5,
              }),
            ],
          }),
          decorative(
            polar({
              id: 'resource-type-center',
              radiusRatio: 0.78,
              angle: { scale: scaleLinear().domain([0, TAU]) },
              radius: { scale: scaleLinear().domain([0, 1]) },
              marks: [
                radialText(centerRows.slice(0, 1), {
                  id: 'resource-type-center-label',
                  angle: 'angle',
                  radius: 'radius',
                  key: 'id',
                  text: 'text',
                  dy: (row) => row.dy,
                  fill: palette.inkSecondary,
                  fontSize: 12,
                  fontWeight: 650,
                }),
                radialText(centerRows.slice(1), {
                  id: 'resource-type-center-value',
                  angle: 'angle',
                  radius: 'radius',
                  key: 'id',
                  text: 'text',
                  dy: (row) => row.dy,
                  fill: palette.ink,
                  fontSize: 27,
                  fontWeight: 760,
                }),
              ],
            }),
          ),
        ],
        color: {
          domain: rows.map((row) => row.type),
          range: rows.map((row) => this.typeColor(row.type)),
        },
        guides: false,
        margin: 0,
      },
      {
        focus: 'nearest',
        keyboard: true,
        tooltip: {
          use: tooltip,
          format: (point) => formatTooltip(point, this.total()),
        },
      },
    );

    return {
      definition,
      ariaLabel: 'Resource portfolio share by resource type',
      ariaDescription: `${this.subtitle()}. Use arrow keys to inspect each slice.`,
      height: 320,
      onFocusChange: (point: ChartPoint<unknown, number, number> | null) =>
        this.activatePoint(point),
      onSelect: (point: ChartPoint<unknown, number, number> | null) =>
        this.activatePoint(point),
    };
  });

  protected selectType(type: ResourceType): void {
    this.activeType.set(type);
  }

  protected typeColor(type: ResourceType): string {
    const palette = this.paletteService.palette();
    return palette.series[RESOURCE_TYPE_ORDER.indexOf(type)] ?? palette.muted;
  }

  protected share(count: number): string {
    const total = this.total();
    return PERCENT.format(total > 0 ? count / total : 0);
  }

  private activatePoint(point: ChartPoint<unknown, number, number> | null): void {
    if (isTypeArc(point?.datum)) {
      this.activeType.set(point.datum.type);
    }
  }
}

function isTypeArc(value: unknown): value is TypeArc {
  return (
    typeof value === 'object'
    && value !== null
    && 'type' in value
    && RESOURCE_TYPE_ORDER.includes((value as { type: ResourceType }).type)
    && 'count' in value
  );
}

function formatTooltip(point: ChartPoint<unknown>, total: number): string {
  if (!isTypeArc(point.datum)) {
    return '';
  }

  const share = total > 0 ? point.datum.count / total : 0;
  return `${point.datum.pluralLabel} · ${whole(point.datum.count)} · ${PERCENT.format(share)}`;
}
