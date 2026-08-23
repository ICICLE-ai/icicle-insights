import { describe, expect, it } from 'vitest';

import { ALL_METRIC_TYPES, RECORDABLE_METRIC_TYPES, isAllTimeMetric } from './insights-api';

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
