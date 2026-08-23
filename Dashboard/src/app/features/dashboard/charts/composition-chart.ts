import { Component, computed, inject, input } from '@angular/core';
import { defineChart, barY } from '@tanstack/charts';
import { Chart } from '@tanstack/charts/angular';
import { colorLegend } from '@tanstack/charts/legend';
import { scaleBand } from '@tanstack/charts/scales/band';
import { scaleLinear } from '@tanstack/charts/scales/linear';
import { tooltip } from '@tanstack/charts/tooltip';

import type { Platform } from '../../../core/api/models';
import { whole } from '../../../shared/format/formatters';
import { PLATFORM_ORDER, platformLabel, resourceTypeLabel } from '../../../shared/format/labels';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { ChartPaletteService } from '../../../shared/charts/chart-palette';

/** One stacked segment: how many resources of a type live on a platform. */
export interface CompositionRow {
  readonly type: string;
  readonly platform: Platform;
  readonly count: number;
}

/**
 * What the catalog is made of: resource type along the axis, platform as the stack.
 *
 * One chart rather than the two donuts the previous dashboard drew. A donut is for part-to-whole
 * at a glance with at most a handful of segments, and comparing six near-equal slices by arc is
 * exactly what it is worst at — bar length is directly comparable where arc is not.
 *
 * Stacking is what earns the colour here. In a plain count-by-type bar chart the axis already
 * names each category, so colouring the bars would spend the palette restating the labels;
 * stacked by platform, hue carries a second dimension the chart could not otherwise show, and
 * the legend makes it readable. Platform colours come from a fixed ordering, so a platform keeps
 * its hue no matter which others are present.
 */
@Component({
  selector: 'app-composition-chart',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure
      heading="Catalog composition"
      subtitle="Resources by type, split by the platform they live on"
    >
      <tanstack-chart chart [options]="chartOptions()" />

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          Resource counts by type and platform.
        </caption>
        <thead>
          <tr>
            <th scope="col">Type</th>
            <th scope="col">Platform</th>
            <th scope="col" class="ins-chart-table__number">Resources</th>
          </tr>
        </thead>
        <tbody>
          @for (row of tableRows(); track row.type + row.platform) {
            <tr>
              <th scope="row">{{ typeLabel(row.type) }}</th>
              <td>{{ label(row.platform) }}</td>
              <td class="ins-chart-table__number">{{ exact(row.count) }}</td>
            </tr>
          }
        </tbody>
      </table>
    </app-chart-figure>
  `,
})
export class CompositionChart {
  readonly rows = input.required<readonly CompositionRow[]>();

  private readonly paletteService = inject(ChartPaletteService);

  protected readonly exact = whole;
  protected readonly label = platformLabel;
  protected readonly typeLabel = resourceTypeLabel;

  protected readonly tableRows = computed(() =>
    [...this.rows()].sort(
      (a, b) => a.type.localeCompare(b.type) || a.platform.localeCompare(b.platform),
    ),
  );

  /** Platforms actually present, in canonical order — which is also their colour order. */
  private readonly presentPlatforms = computed(() => {
    const present = new Set(this.rows().map((row) => row.platform));
    return PLATFORM_ORDER.filter((platform) => present.has(platform));
  });

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const rows = this.rows();
    const platforms = this.presentPlatforms();

    return {
      definition: defineChart({
        marks: [
          barY(rows, {
            id: 'composition',
            x: (row: CompositionRow) => resourceTypeLabel(row.type),
            y: 'count',
            // `z` groups the stack; `color` is what the colour scale receives. Both are the
            // platform, so each stacked segment is one platform's share of that type.
            z: 'platform',
            color: 'platform',
            // A hairline in the surface colour separates adjacent segments, so two similar hues
            // stacked together still read as two blocks rather than one.
            stroke: palette.surface,
            strokeWidth: 1,
            radius: 2,
            maxThickness: 56,
          }),
        ],
        x: { scale: () => scaleBand<string>().padding(0.25) },
        y: {
          scale: scaleLinear,
          nice: true,
          grid: true,
          axis: { ticks: { format: (value: number) => whole(value) } },
        },
        color: {
          // Domain and range are pinned together so a platform's hue is decided by its position
          // in the canonical ordering, never by the order rows happen to arrive in.
          domain: platforms,
          range: platforms.map((platform) => palette.series[PLATFORM_ORDER.indexOf(platform)]),
          legend: colorLegend({ placement: 'bottom' }),
        },
        tooltip,
      }),
      ariaLabel: 'Resource counts by type, stacked by platform',
      ariaDescription: `Covers ${platforms.map(platformLabel).join(', ')}.`,
      height: 320,
    };
  });
}
