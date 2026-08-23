import { HttpClient, HttpParams } from '@angular/common/http';
import { Service, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';

import { INSIGHTS_CONFIG } from '../config';
import type { Account, Metric, MetricType, Release, Resource } from './models';

/**
 * The server's own ceiling on `GET /api/metrics`, from `MetricController.maxLimit`.
 *
 * Asking for more is a 400, not a larger page — `requireInRange(limit, 1...maxLimit)` rejects it.
 */
export const METRIC_PAGE_LIMIT = 1000;

/**
 * Every metric type the API can return, from the `MetricType` enum in `Models/Metric.swift`.
 *
 * The list is closed, which is what makes the fan-out in `loadMetrics` safe. Keep it in step with
 * the Swift enum: a type missing here is simply never fetched, and its charts never appear.
 */
export const ALL_METRIC_TYPES: readonly MetricType[] = [
  'authentications',
  'clones',
  'downloads',
  'forks',
  'likes',
  'pulls',
  'stars',
  'subscribers',
  'views',
  'authenticationsAllTime',
  'clonesAllTime',
  'downloadsAllTime',
  'pullsAllTime',
  'viewsAllTime',
];

/**
 * True for the running totals the server derives rather than accepts.
 *
 * Takes a bare `string` because the dashboard's metric pickers carry their option types that way
 * — and a suffix test needs no narrower domain than the one it actually inspects.
 */
export const isAllTimeMetric = (type: string): boolean => type.endsWith('AllTime');

/**
 * The metric types a human may record.
 *
 * The `*AllTime` twins are excluded because the server owns them: `MetricController` rejects a
 * write naming one and folds every accepted reading into its twin instead. Offering them in a
 * picker would only produce a 422 — and before that guard existed, a hand-typed total drifted
 * from the collector's the moment the next sweep ran.
 */
export const RECORDABLE_METRIC_TYPES: readonly MetricType[] = ALL_METRIC_TYPES.filter(
  (type) => !isAllTimeMetric(type),
);

/** One metric type's readings, plus whether the response hit the server's page ceiling. */
export interface MetricSlice {
  readonly type: MetricType;
  /** Oldest first — the order the API returns, which is already chart x-axis order. */
  readonly readings: Metric[];
  /**
   * True when the response came back exactly at the limit, meaning older readings exist beyond
   * what was returned. Any total computed from a saturated slice covers a window, not all time,
   * and the UI has to say so rather than implying otherwise.
   */
  readonly saturated: boolean;
}

/** Reads from the Insights API. Writes live in the admin feature. */
@Service()
export class InsightsApi {
  private readonly http = inject(HttpClient);
  private readonly config = inject(INSIGHTS_CONFIG);

  private url(path: string): string {
    return `${this.config.apiBase}${path}`;
  }

  loadAccounts(): Promise<Account[]> {
    return firstValueFrom(this.http.get<Account[]>(this.url('/accounts')));
  }

  loadResources(): Promise<Resource[]> {
    return firstValueFrom(this.http.get<Resource[]>(this.url('/resources')));
  }

  loadReleases(): Promise<Release[]> {
    return firstValueFrom(this.http.get<Release[]>(this.url('/releases')));
  }

  /**
   * Fetches readings for every metric type, one request per type, in parallel.
   *
   * **Why not one unscoped request.** `GET /api/metrics` returns the newest `limit` rows across
   * *all* resources and types, capped at 1000. The previous dashboard fetched exactly that and
   * computed portfolio totals from it, which is wrong in a way nothing surfaces: past 1000 total
   * readings the response is a truncated, type-biased window, and a "total across all resources"
   * derived from it silently omits whatever fell off the end.
   *
   * Discovering the active types from such a response and then fanning out over those would
   * inherit the same flaw — a type recorded hourly crowds a type recorded monthly out of the
   * newest 1000 entirely, so the rare one would never be discovered at all. Fanning out over the
   * closed enum instead is complete by construction.
   *
   * The cost is 14 requests against a 300-per-minute per-IP ceiling. Each is scoped to one type,
   * so the 1000-row cap now applies per type rather than across everything, and `saturated`
   * reports honestly when even that is not enough.
   *
   * @param resourceID Narrows every request to one resource, making the result exact for a
   *   single-resource view rather than merely well-bounded.
   */
  async loadMetrics(resourceID?: string): Promise<MetricSlice[]> {
    const slices = await Promise.all(
      ALL_METRIC_TYPES.map((type) => this.loadMetricSlice(type, resourceID)),
    );

    return slices.filter((slice) => slice.readings.length > 0);
  }

  private async loadMetricSlice(type: MetricType, resourceID?: string): Promise<MetricSlice> {
    let params = new HttpParams().set('type', type).set('limit', METRIC_PAGE_LIMIT);
    if (resourceID) {
      params = params.set('resourceID', resourceID);
    }

    const readings = await firstValueFrom(
      this.http.get<Metric[]>(this.url('/metrics'), { params }),
    );

    return { type, readings, saturated: readings.length >= METRIC_PAGE_LIMIT };
  }
}
