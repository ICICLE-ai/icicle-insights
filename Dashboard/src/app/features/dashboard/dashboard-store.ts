import { Service, computed, inject, resource, signal } from '@angular/core';

import { InsightsApi, type MetricSlice } from '../../core/api/insights-api';
import type { Account, Metric, Platform, Release, Resource } from '../../core/api/models';
import { newestRecordedAt } from '../../core/analytics/metrics';
import { pluralize } from '../../shared/format/formatters';
import {
  PLATFORM_ORDER,
  metricLabel,
  platformFilterIncludes,
  platformFilterLabel,
  type PlatformFilter,
} from '../../shared/format/labels';

/** How much of the catalog the current filters admit. Decides which panels are meaningful. */
export type Scope = 'all' | 'platform' | 'resource';

/** Everything one load of the dashboard needs, plus the indexes derived from it. */
interface Catalog {
  readonly accounts: Account[];
  readonly resources: Resource[];
  readonly releases: Release[];
  readonly metricSlices: MetricSlice[];
  /** Resource id → display name. */
  readonly resourceNames: ReadonlyMap<string, string>;
  /** Resource id → the platform of the account that owns it. */
  readonly resourcePlatform: ReadonlyMap<string, Platform>;
  /** Platforms that actually have an account, in canonical order, unknowns last. */
  readonly platforms: Platform[];
}

const EMPTY_CATALOG: Catalog = {
  accounts: [],
  resources: [],
  releases: [],
  metricSlices: [],
  resourceNames: new Map(),
  resourcePlatform: new Map(),
  platforms: [],
};

/**
 * Loads the public dashboard's data once and derives every view from it in memory.
 *
 * Filtering client-side rather than refetching is deliberate: the metric fan-out is fourteen
 * requests, and re-running it on every dropdown change would spend the per-IP rate limit on work
 * whose answer is already in hand. The one thing refetching would buy is accuracy on a saturated
 * slice — see `saturatedTypes`, which surfaces that case rather than hiding it.
 */
@Service()
export class DashboardStore {
  private readonly api = inject(InsightsApi);

  private readonly platformFilterState = signal<PlatformFilter>('all');
  private readonly resourceFilterState = signal<string | 'all'>('all');

  readonly platformFilter = this.platformFilterState.asReadonly();
  readonly resourceFilter = this.resourceFilterState.asReadonly();

  private readonly data = resource({
    loader: async (): Promise<Catalog> => {
      const [accounts, resources, releases, metricSlices] = await Promise.all([
        this.api.loadAccounts(),
        this.api.loadResources(),
        this.api.loadReleases(),
        this.api.loadMetrics(),
      ]);

      return { accounts, resources, releases, metricSlices, ...buildIndexes(accounts, resources) };
    },
  });

  readonly isLoading = computed(() => this.data.isLoading());
  readonly error = computed(() => this.data.error());
  readonly catalog = computed(() => this.data.value() ?? EMPTY_CATALOG);

  /** Platforms offered in the filter — only those an account actually exists for. */
  readonly platforms = computed(() => this.catalog().platforms);

  /**
   * Resource count per platform, in canonical order.
   *
   * Feeds the platform rail, which is both the filter and a view of how the catalog is
   * distributed. Counts are of the whole catalog rather than the current scope on purpose: the
   * rail is what you use to *change* scope, so it has to keep showing what is behind each option
   * rather than collapsing to the one already chosen.
   */
  readonly platformCounts = computed(() => {
    const catalog = this.catalog();
    const counts = new Map<Platform, number>();

    for (const platform of catalog.resourcePlatform.values()) {
      counts.set(platform, (counts.get(platform) ?? 0) + 1);
    }

    return catalog.platforms.map((platform) => ({
      platform,
      count: counts.get(platform) ?? 0,
    }));
  });

  /** Resources offered in the filter, narrowed by the platform filter and sorted by name. */
  readonly selectableResources = computed(() => {
    const catalog = this.catalog();
    const platform = this.platformFilterState();

    return catalog.resources
      .filter((resource) => {
        const resourcePlatform = catalog.resourcePlatform.get(resource.id ?? '');
        return resourcePlatform ? platformFilterIncludes(platform, resourcePlatform) : false;
      })
      .sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''));
  });

  readonly scope = computed<Scope>(() => {
    if (this.resourceFilterState() !== 'all') {
      return 'resource';
    }
    return this.platformFilterState() !== 'all' ? 'platform' : 'all';
  });

  /** The resources the current filters admit. */
  readonly scopedResources = computed(() => {
    const catalog = this.catalog();
    const resourceID = this.resourceFilterState();
    const platform = this.platformFilterState();

    if (resourceID !== 'all') {
      return catalog.resources.filter((r) => r.id === resourceID);
    }
    if (platform !== 'all') {
      return catalog.resources.filter((resource) => {
        const resourcePlatform = catalog.resourcePlatform.get(resource.id ?? '');
        return resourcePlatform ? platformFilterIncludes(platform, resourcePlatform) : false;
      });
    }
    return catalog.resources;
  });

  /** Metric slices with each slice's readings narrowed to the scoped resources. */
  readonly scopedSlices = computed(() => {
    const admitted = new Set(this.scopedResources().map((r) => r.id ?? ''));

    return this.catalog()
      .metricSlices.map((slice) => ({
        ...slice,
        readings: slice.readings.filter((m) => admitted.has(m.resourceID ?? '')),
      }))
      .filter((slice) => slice.readings.length > 0);
  });

  /** Releases the current filters admit, newest first, undated ones dropped. */
  readonly scopedReleases = computed(() => {
    const admitted = new Set(this.scopedResources().map((r) => r.id ?? ''));

    return this.catalog()
      .releases.filter((r) => r.releasedAt && admitted.has(r.resourceID ?? ''))
      .sort((a, b) => Date.parse(b.releasedAt!) - Date.parse(a.releasedAt!));
  });

  /**
   * Metric types whose fetch came back at the server's page ceiling.
   *
   * Any all-time figure derived from these covers the most recent 1,000 readings rather than the
   * full history, and the UI is obliged to say so. Reporting nothing here would reproduce the
   * exact defect this dashboard replaces.
   */
  readonly saturatedTypes = computed(() =>
    this.catalog()
      .metricSlices.filter((slice) => slice.saturated)
      .map((slice) => slice.type),
  );

  /** When the newest reading in the whole catalog was recorded. */
  readonly snapshotTime = computed(() =>
    newestRecordedAt(this.catalog().metricSlices.flatMap((slice) => slice.readings)),
  );

  /** Total readings held, for the masthead summary. */
  readonly readingCount = computed(() =>
    this.catalog().metricSlices.reduce((sum, slice) => sum + slice.readings.length, 0),
  );

  /**
   * What the filters currently describe, spelled out so the scope is never implicit.
   *
   * Lives on the store rather than in one component because every section states it — in a
   * heading, a table caption, or a chart's accessible name — and three copies would drift.
   */
  readonly scopeLabel = computed(() => {
    const catalog = this.catalog();

    if (this.scope() === 'resource') {
      return catalog.resourceNames.get(this.resourceFilterState()) ?? 'Selected resource';
    }
    if (this.scope() === 'platform') {
      return platformFilterLabel(this.platformFilterState());
    }
    return 'Overview';
  });

  /** One sentence of counts describing everything held. */
  readonly summary = computed(() => {
    const catalog = this.catalog();
    const platforms = new Set(catalog.resourcePlatform.values()).size;

    return [
      pluralize(platforms, 'registry', 'registries'),
      pluralize(catalog.resources.length, 'resource'),
      pluralize(this.readingCount(), 'reading'),
      pluralize(catalog.releases.length, 'release'),
    ].join('  ·  ');
  });

  /** Whether any metric data survives the current filters. */
  readonly hasData = computed(() => this.scopedSlices().length > 0);

  /**
   * Metric types whose figures cover a window rather than the full history.
   *
   * Surfaced as a sentence rather than a footnote: a total that silently omits older readings is
   * the specific defect this dashboard exists to stop repeating.
   */
  readonly saturationNotice = computed(() => {
    const types = this.saturatedTypes();
    if (types.length === 0) {
      return null;
    }

    return `${types.map(metricLabel).join(', ')} — showing the most recent 1,000 readings per metric. Totals cover that window, not all time.`;
  });

  /**
   * Selects a platform and clears the resource filter.
   *
   * Clearing is not optional: the previously selected resource may belong to a different
   * platform, which would leave the two filters describing an empty intersection and the page
   * blank for no visible reason.
   */
  setPlatformFilter(platform: PlatformFilter): void {
    this.platformFilterState.set(platform);
    this.resourceFilterState.set('all');
  }

  setResourceFilter(resourceID: string | 'all'): void {
    this.resourceFilterState.set(resourceID);
  }

  reload(): void {
    this.data.reload();
  }
}

/** Builds the lookups every view needs, so no view walks the account list per resource. */
function buildIndexes(
  accounts: readonly Account[],
  resources: readonly Resource[],
): Pick<Catalog, 'resourceNames' | 'resourcePlatform' | 'platforms'> {
  const resourceNames = new Map<string, string>();
  const accountPlatform = new Map<string, Platform>();
  const resourcePlatform = new Map<string, Platform>();

  for (const account of accounts) {
    if (account.id && account.platform) {
      accountPlatform.set(account.id, account.platform);
    }
  }

  for (const resource of resources) {
    if (!resource.id) {
      continue;
    }
    resourceNames.set(resource.id, resource.name ?? 'Unnamed resource');

    const platform = resource.accountID ? accountPlatform.get(resource.accountID) : undefined;
    if (platform) {
      resourcePlatform.set(resource.id, platform);
    }
  }

  const present = new Set(accountPlatform.values());
  const platforms = [
    ...PLATFORM_ORDER.filter((p) => present.has(p)),
    // A platform the server knows about but this client does not still gets an entry, sorted
    // after the ones we can order deliberately, rather than vanishing from the filter.
    ...[...present].filter((p) => !PLATFORM_ORDER.includes(p)).sort(),
  ];

  return { resourceNames, resourcePlatform, platforms };
}

/** Re-exported for the panels, which take plain readings rather than the store. */
export type { Metric };
