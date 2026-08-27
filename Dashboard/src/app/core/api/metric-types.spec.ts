import { describe, expect, it } from 'vitest';

import { ALL_METRIC_TYPES, RECORDABLE_METRIC_TYPES, isAllTimeMetric } from './insights-api';
import type { MetricType } from './models';

describe('ALL_METRIC_TYPES', () => {
  it('includes every member of the MetricType union', () => {
    // A `Record<MetricType, true>` forces this object literal to name every member of the union
    // — TypeScript fails the build if one is missing, the same way `just web-build`'s AOT check
    // (not `just web-test`) is what actually caught Critical 2: `ALL_METRIC_TYPES` had drifted
    // from `MetricType` with no compile error, because a `readonly MetricType[]` gives no
    // exhaustiveness check on its own. Keeping that guarantee here means the next type added to
    // the union fails *this* fast unit test instead of silently never being fetched.
    const everyMetricType: Record<MetricType, true> = {
      authentications: true,
      clones: true,
      deployments: true,
      downloads: true,
      forks: true,
      likes: true,
      pulls: true,
      stars: true,
      subscribers: true,
      views: true,
      authenticationsAllTime: true,
      clonesAllTime: true,
      downloadsAllTime: true,
      pullsAllTime: true,
      viewsAllTime: true,
    };

    for (const type of Object.keys(everyMetricType) as MetricType[]) {
      expect(ALL_METRIC_TYPES).toContain(type);
    }
    // Catches the reverse drift too: an entry in `ALL_METRIC_TYPES` that names a type removed
    // from the union would otherwise pass the loop above by never being checked at all.
    expect(ALL_METRIC_TYPES.length).toBe(Object.keys(everyMetricType).length);
  });
});

describe('RECORDABLE_METRIC_TYPES', () => {
  it('excludes every derived all-time total', () => {
    // The API answers 422 for these, so offering one in a picker only produces a failed request.
    expect(RECORDABLE_METRIC_TYPES.filter(isAllTimeMetric)).toStrictEqual([]);
  });

  it('keeps every collected type the API can return', () => {
    const collected = ALL_METRIC_TYPES.filter((type) => !isAllTimeMetric(type));
    expect(RECORDABLE_METRIC_TYPES).toStrictEqual(collected);
  });

  it('stays derived from the full list rather than maintained by hand', () => {
    // A type added to `ALL_METRIC_TYPES` must appear here without a second edit, or the picker
    // silently stops offering it.
    expect(RECORDABLE_METRIC_TYPES.length).toBe(
      ALL_METRIC_TYPES.length - ALL_METRIC_TYPES.filter(isAllTimeMetric).length,
    );
  });
});

describe('isAllTimeMetric', () => {
  it('recognises the suffix the Swift enum uses', () => {
    expect(isAllTimeMetric('downloadsAllTime')).toBe(true);
    expect(isAllTimeMetric('pullsAllTime')).toBe(true);
  });

  it('does not mistake a collected type for its twin', () => {
    expect(isAllTimeMetric('downloads')).toBe(false);
    expect(isAllTimeMetric('stars')).toBe(false);
  });
});
