import { Component, computed, inject, linkedSignal, signal } from '@angular/core';
import { TableModule } from '@openng/optimus-ui/table';

import { currentTotal, latestByResource, totalSeries } from '../../core/analytics/metrics';
import type { MetricType, Platform } from '../../core/api/models';
import { pluralize } from '../../shared/format/formatters';
import { isPlatformGroup, metricLabel } from '../../shared/format/labels';
import { ErrorNotice } from '../../shared/ui/error-notice';
import { AppNav } from '../../shared/ui/app-nav';
import { StatTile } from '../../shared/ui/stat-tile';
import { StructureSunburst, type StructureRow } from './charts/structure-sunburst';
import { TopResourcesChart, type ResourceReading } from './charts/top-resources-chart';
import {
  ALL_TREND_METRICS,
  TrendChart,
  type TrendMetricOption,
  type TrendSeries,
} from './charts/trend-chart';
import { DashboardStore } from './dashboard-store';
import { FilterBar } from './filter-bar';
import { PlatformPicker } from './platform-picker';
import { ReleaseGraph } from './charts/release-graph';
import { ScopeProfile, type ScopeProfileStat } from './scope-profile';

/** One headline metric, already reduced to what the tile renders. */
interface HeadlineMetric {
  readonly type: string;
  readonly label: string;
  readonly total: number;
  readonly coverage: number;
}

type DashboardSectionId = 'headline' | 'reach' | 'trends' | 'releases';

interface DashboardSectionOption {
  readonly id: DashboardSectionId;
  readonly label: string;
}

interface ReleaseResourceLink {
  readonly id: string;
  readonly name: string;
}

interface ReleaseMonthRow {
  readonly month: string;
  readonly resourceCount: number;
  readonly resources: readonly ReleaseResourceLink[];
}

type ReleaseDisplay = 'cadence' | 'lineage';

/** Stable presentation order for the four cumulative institute-wide headline measures. */
const HEADLINE_ALL_TIME_TYPES: readonly MetricType[] = [
  'viewsAllTime',
  'clonesAllTime',
  'pullsAllTime',
  'downloadsAllTime',
];

const DASHBOARD_SECTION_OPTIONS: readonly DashboardSectionOption[] = [
  { id: 'headline', label: 'Headline' },
  { id: 'reach', label: 'Reach by resource' },
  { id: 'trends', label: 'Over time' },
  { id: 'releases', label: 'Software Releases' },
];

@Component({
  selector: 'app-dashboard',
  imports: [
    AppNav,
    ErrorNotice,
    FilterBar,
    PlatformPicker,
    ReleaseGraph,
    ScopeProfile,
    StatTile,
    StructureSunburst,
    TableModule,
    TopResourcesChart,
    TrendChart,
  ],
  templateUrl: './dashboard.html',
  styleUrl: './dashboard.css',
})
export class Dashboard {
  protected readonly store = inject(DashboardStore);
  protected readonly releaseDisplay = signal<ReleaseDisplay>('cadence');

  /** Masthead line: what this page is showing, in one sentence of counts. */
  protected readonly summary = computed(() => {
    const catalog = this.store.catalog();
    const platforms = new Set(catalog.resourcePlatform.values()).size;

    return [
      pluralize(platforms, 'registry', 'registries'),
      pluralize(catalog.resources.length, 'resource'),
      pluralize(this.store.readingCount(), 'reading'),
      pluralize(catalog.releases.length, 'release'),
    ].join('  ·  ');
  });

  /** What the filters currently describe, spelled out so the scope is never implicit. */
  protected readonly scopeLabel = this.store.scopeLabel;

  /**
   * Headline metrics, largest first.
   *
   * Ordered by current standing rather than a fixed list, because which metric matters most
   * differs per platform — stars lead on GitHub, downloads on PyPI — and a fixed order would
   * bury the interesting figure on most selections.
   */
  protected readonly headlines = computed<HeadlineMetric[]>(() =>
    this.store
      .scopedSlices()
      .map((slice) => ({
        type: slice.type,
        label: metricLabel(slice.type),
        total: currentTotal(slice.readings),
        coverage: latestByResource(slice.readings).size,
      }))
      .filter((entry) => entry.coverage > 0)
      .sort((a, b) => b.total - a.total),
  );

  /**
   * The institute overview is intentionally cumulative: mixing rolling-window and all-time
   * measures there would make the numbers look directly comparable when their windows are not.
   * A selected registry instead uses its four leading available measures because platforms do
   * not expose the same cumulative fields; every non-lifetime window remains explicit in its
   * label. The exact full set remains below in both cases.
   */
  protected readonly visibleHeadlines = computed(() => {
    const headlines = this.headlines();
    if (this.store.scope() !== 'all') {
      return headlines.slice(0, 4);
    }

    return HEADLINE_ALL_TIME_TYPES.flatMap((type) => {
      const headline = headlines.find((entry) => entry.type === type);
      return headline ? [headline] : [];
    });
  });

  /* Catalog presence is enough to render a useful profile. A registry group can legitimately
   * contain known resources before metrics or releases have been collected; treating that as
   * "nothing here" would erase the distinction between zero coverage and no matching scope. */
  protected readonly hasData = computed(() => this.store.scopedResources().length > 0);

  /**
   * Metric types whose figures cover a window rather than the full history.
   *
   * Rendered as a visible notice rather than a footnote: a total that silently omits older
   * readings is the specific defect this dashboard exists to stop repeating.
   */
  protected readonly saturationNotice = computed(() => {
    const types = this.store.saturatedTypes();
    if (types.length === 0) {
      return null;
    }

    return `${types.map(metricLabel).join(', ')} — showing the most recent 1,000 readings per metric. Totals cover that window, not all time.`;
  });

  /** Resource counts per (type, registry) pair, feeding the structure sunburst. */
  protected readonly structureRows = computed<StructureRow[]>(() => {
    const catalog = this.store.catalog();
    const counts = new Map<string, StructureRow>();

    for (const resource of this.store.scopedResources()) {
      const platform = catalog.resourcePlatform.get(resource.id ?? '');
      if (!resource.type || !platform) {
        continue;
      }

      const key = `${resource.type}|${platform}`;
      const existing = counts.get(key);
      counts.set(key, {
        type: resource.type,
        platform: platform as Platform,
        count: (existing?.count ?? 0) + 1,
      });
    }

    return [...counts.values()];
  });

  /**
   * Hidden at resource scope, where the sunburst would be a single wedge — the anti-pattern
   * catalog's one-bar bar chart, saying less than the sentence already in the masthead.
   */
  protected readonly showStructure = computed(
    () =>
      this.store.scope() !== 'resource' &&
      new Set(this.structureRows().map((row) => row.type)).size > 1,
  );

  /**
   * Useful replacement for the radial when a selected registry contains one resource kind.
   * Counts are deliberately heterogeneous and therefore remain separate instead of being forced
   * into slices or bars that would imply a shared quantitative scale.
   */
  protected readonly scopeProfile = computed(() => {
    const resources = this.store.scopedResources();
    const resourceKinds = new Set(
      resources.flatMap((resource) => (resource.type ? [resource.type] : [])),
    );
    const measuredResources = new Set(
      this.store
        .scopedSlices()
        .flatMap((slice) => slice.readings)
        .flatMap((reading) => (reading.resourceID ? [reading.resourceID] : [])),
    );
    const coverage =
      resources.length > 0 ? Math.round((measuredResources.size / resources.length) * 100) : 0;
    const stats: readonly ScopeProfileStat[] = [
      {
        label: 'Resources',
        value: String(resources.length),
        context: 'catalog entries',
      },
      {
        label: 'Resource kinds',
        value: String(resourceKinds.size),
        context: 'represented types',
      },
      {
        label: 'Metric types',
        value: String(this.store.scopedSlices().length),
        context: 'reported series',
      },
      {
        label: 'Releases',
        value: String(this.store.scopedReleases().length),
        context: 'recorded versions',
      },
    ];

    return {
      heading: this.scopeLabel(),
      profileLabel:
        this.store.scope() === 'resource'
          ? 'Resource profile'
          : isPlatformGroup(this.store.platformFilter())
            ? 'Registry group profile'
            : 'Registry profile',
      subtitle: 'Catalog footprint and measurement coverage for this selection.',
      stats,
      coverage,
      coverageLabel: `${pluralize(measuredResources.size, 'resource')} represented in the loaded metric window`,
    };
  });

  /**
   * Metrics selectable in the top-resources chart, widest coverage first.
   *
   * Coverage rather than magnitude decides the default: a metric only four resources report
   * makes a four-bar chart however large its numbers are, so it is a poor thing to open on.
   */
  protected readonly sizingOptions = computed(() =>
    this.store
      .scopedSlices()
      .map((slice) => ({
        type: slice.type,
        label: metricLabel(slice.type),
        coverage: latestByResource(slice.readings).size,
      }))
      .filter((option) => option.coverage > 0)
      .sort((a, b) => b.coverage - a.coverage)
      .map(({ type, label }) => ({ type, label })),
  );

  /**
   * Which metric the top-resources chart ranks by.
   *
   * `linkedSignal` because it is derived from the available options but must survive them
   * changing: a plain signal would keep a metric that a filter has removed, leaving an empty
   * chart, and a computed could not be set by the user at all.
   */
  protected readonly sizingMetric = linkedSignal<readonly string[], string>({
    source: () => this.sizingOptions().map((option) => option.type),
    computation: (types, previous) =>
      previous && types.includes(previous.value) ? previous.value : (types[0] ?? ''),
  });

  /** One row per resource holding a reading for the selected metric. */
  protected readonly topResourceRows = computed<ResourceReading[]>(() => {
    const catalog = this.store.catalog();
    const slice = this.store.scopedSlices().find((s) => s.type === this.sizingMetric());
    if (!slice) {
      return [];
    }

    return [...latestByResource(slice.readings).values()].flatMap((latest) => {
      const platform = catalog.resourcePlatform.get(latest.resourceID);
      if (!platform) {
        return [];
      }

      return [
        {
          resourceID: latest.resourceID,
          name: catalog.resourceNames.get(latest.resourceID) ?? 'Unknown resource',
          platform: platform as Platform,
          value: latest.value,
        },
      ];
    });
  });

  /**
   * Releases per calendar month, newest first.
   *
   * The overview used to list all 83 releases, which is a log rather than a finding — nobody
   * reads to the bottom, and the thing worth seeing is the cadence. Aggregating by month shows
   * whether the institute ships steadily or in bursts, and the per-release detail stays one
   * click away at resource scope.
   */
  protected readonly releaseMonths = computed<ReleaseMonthRow[]>(() => {
    const catalog = this.store.catalog();
    const months = new Map<string, { month: string; resources: Set<string> }>();

    for (const release of this.store.scopedReleases()) {
      const time = Date.parse(release.releasedAt ?? '');
      if (!Number.isFinite(time)) {
        continue;
      }

      const date = new Date(time);
      // Sortable key built from UTC parts. Formatting first and grouping on the label would
      // collide across locales and sort alphabetically, putting April before January.
      const key = `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, '0')}`;
      const entry = months.get(key) ?? { month: key, resources: new Set<string>() };
      if (release.resourceID) {
        entry.resources.add(release.resourceID);
      }
      months.set(key, entry);
    }

    return [...months.values()]
      .sort((a, b) => b.month.localeCompare(a.month))
      .map((entry) => {
        // Keep the resource id beside its display name: the table renders names, while selecting
        // one must scope the dashboard by the stable id rather than a potentially duplicated name.
        const resources = [...entry.resources]
          .map((id) => ({ id, name: catalog.resourceNames.get(id) ?? 'Unnamed resource' }))
          .sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));

        return {
          month: entry.month,
          resourceCount: resources.length,
          resources,
        };
      });
  });

  /**
   * Trend panels, longest series first.
   *
   * A single reading is a point, not a trend, so series with fewer than two are dropped rather
   * than drawn as a lone dot on an empty grid. With one collection sweep recorded, that means no
   * trends appear at all — which is correct, not a fault.
   */
  protected readonly trendSections = computed<TrendSeries[]>(() =>
    this.store
      .scopedSlices()
      .map((slice) => ({
        type: slice.type,
        label: metricLabel(slice.type),
        points: totalSeries(slice.readings),
      }))
      .filter((section) => section.points.length > 1)
      .sort((a, b) => b.points.length - a.points.length),
  );

  /** Defaults to comparison, while preserving an isolated metric across scope changes. */
  protected readonly trendMetric = linkedSignal<readonly string[], string>({
    source: () => this.trendSections().map((section) => section.type),
    computation: (types, previous) =>
      previous && (previous.value === ALL_TREND_METRICS || types.includes(previous.value))
        ? previous.value
        : ALL_TREND_METRICS,
  });

  protected readonly trendOptions = computed<readonly TrendMetricOption[]>(() => [
    { type: ALL_TREND_METRICS, label: 'All metrics' },
    ...this.trendSections().map(({ type, label }) => ({ type, label })),
  ]);

  protected readonly selectedTrendSlot = computed(() =>
    Math.max(
      0,
      this.trendSections().findIndex((section) => section.type === this.trendMetric()),
    ),
  );

  /** The section navigator only offers views backed by visible content. */
  protected readonly dashboardSections = computed<readonly DashboardSectionOption[]>(() =>
    DASHBOARD_SECTION_OPTIONS.filter((section) => {
      switch (section.id) {
        case 'reach':
          return this.topResourceRows().length > 0;
        case 'trends':
          return this.trendSections().length > 0;
        case 'releases':
          return this.store.scopedReleases().length > 0;
        default:
          return true;
      }
    }),
  );

  protected readonly activeDashboardSection = linkedSignal<
    readonly DashboardSectionId[],
    DashboardSectionId
  >({
    source: () => this.dashboardSections().map((section) => section.id),
    computation: (sections, previous) =>
      previous && sections.includes(previous.value) ? previous.value : (sections[0] ?? 'headline'),
  });

  protected showDashboardSection(section: DashboardSectionId): boolean {
    return this.activeDashboardSection() === section;
  }

  protected selectDashboardSection(section: DashboardSectionId): void {
    this.activeDashboardSection.set(section);
  }

  protected selectReleasedResource(resourceID: string): void {
    this.store.setResourceFilter(resourceID);
  }

  protected coverageLabel(count: number): string {
    return `Current total across ${pluralize(count, 'resource')}`;
  }
}
