import { describe, expect, it } from 'vitest';

import type { Metric } from '../api/models';
import {
  currentTotal,
  latestByResource,
  newestRecordedAt,
  totalSeries,
} from './metrics';

/** Builds a reading, keeping the tests readable when only one field is interesting. */
function reading(resourceID: string, value: number, recordedAt: string): Metric {
  return { id: `${resourceID}-${recordedAt}`, resourceID, reading: value, recordedAt, type: 'stars' };
}

describe('totalSeries', () => {
  it('carries each resource forward so a later sweep does not drop earlier resources', () => {
    // The defect this guards against: summing per timestamp instead of carrying forward leaves
    // the final point holding only resource-b, reporting 5 when the portfolio actually holds 15.
    const series = totalSeries([
      reading('a', 10, '2026-01-01T00:00:00Z'),
      reading('b', 5, '2026-01-02T00:00:00Z'),
    ]);

    expect(series.map((p) => p.value)).toEqual([10, 15]);
  });

  it('replaces a resource previous value rather than accumulating it', () => {
    const series = totalSeries([
      reading('a', 10, '2026-01-01T00:00:00Z'),
      reading('a', 12, '2026-01-02T00:00:00Z'),
    ]);

    // 12, not 22 — a new reading for a resource supersedes its old one.
    expect(series.map((p) => p.value)).toEqual([10, 12]);
  });

  it('sorts chronologically regardless of input order', () => {
    const series = totalSeries([
      reading('a', 30, '2026-03-01T00:00:00Z'),
      reading('a', 10, '2026-01-01T00:00:00Z'),
      reading('a', 20, '2026-02-01T00:00:00Z'),
    ]);

    expect(series.map((p) => p.value)).toEqual([10, 20, 30]);
  });

  it('collapses readings sharing a timestamp into one point holding the total', () => {
    // A bulk import writes many resources at the same instant; one point per resource would
    // draw a vertical staircase that means nothing.
    const series = totalSeries([
      reading('a', 10, '2026-01-01T00:00:00Z'),
      reading('b', 5, '2026-01-01T00:00:00Z'),
      reading('c', 1, '2026-01-01T00:00:00Z'),
    ]);

    expect(series).toHaveLength(1);
    expect(series[0].value).toBe(16);
  });

  it('drops readings missing the fields the arithmetic needs', () => {
    const series = totalSeries([
      reading('a', 10, '2026-01-01T00:00:00Z'),
      { id: 'no-resource', reading: 99, recordedAt: '2026-01-02T00:00:00Z' },
      { id: 'no-reading', resourceID: 'b', recordedAt: '2026-01-03T00:00:00Z' },
      { id: 'no-date', resourceID: 'c', reading: 99 },
      { id: 'bad-date', resourceID: 'd', reading: 99, recordedAt: 'not-a-date' },
    ]);

    // Only the usable reading survives; the rest would otherwise count as zero at the epoch.
    expect(series).toEqual([{ time: Date.parse('2026-01-01T00:00:00Z'), value: 10 }]);
  });

  it('returns an empty series for no readings', () => {
    expect(totalSeries([])).toEqual([]);
  });

  it('tracks many resources across many sweeps', () => {
    // Guards the incremental running total against the re-sum-per-reading version it replaced:
    // both must agree, and only one of them stays linear.
    const metrics: Metric[] = [];
    for (let sweep = 1; sweep <= 3; sweep++) {
      for (let r = 0; r < 4; r++) {
        metrics.push(reading(`r${r}`, sweep * 10, `2026-0${sweep}-01T00:00:00Z`));
      }
    }

    expect(totalSeries(metrics).map((p) => p.value)).toEqual([40, 80, 120]);
  });
});

describe('latestByResource', () => {
  it('picks the newest reading by timestamp, not by array position', () => {
    const latest = latestByResource([
      reading('a', 50, '2026-03-01T00:00:00Z'),
      reading('a', 10, '2026-01-01T00:00:00Z'),
    ]);

    expect(latest.get('a')?.value).toBe(50);
  });

  it('keeps one entry per resource', () => {
    const latest = latestByResource([
      reading('a', 1, '2026-01-01T00:00:00Z'),
      reading('a', 2, '2026-02-01T00:00:00Z'),
      reading('b', 3, '2026-01-01T00:00:00Z'),
    ]);

    expect([...latest.keys()].sort()).toEqual(['a', 'b']);
    expect(latest.get('a')?.value).toBe(2);
  });
});

describe('currentTotal', () => {
  it('sums the newest reading of every resource', () => {
    const total = currentTotal([
      reading('a', 10, '2026-01-01T00:00:00Z'),
      reading('a', 25, '2026-02-01T00:00:00Z'),
      reading('b', 5, '2026-01-01T00:00:00Z'),
    ]);

    expect(total).toBe(30);
  });

  it('is zero when nothing is usable', () => {
    expect(currentTotal([])).toBe(0);
  });
});

describe('newestRecordedAt', () => {
  it('finds the latest timestamp', () => {
    const newest = newestRecordedAt([
      reading('a', 1, '2026-01-01T00:00:00Z'),
      reading('b', 1, '2026-05-01T00:00:00Z'),
      reading('c', 1, '2026-03-01T00:00:00Z'),
    ]);

    expect(newest).toBe(Date.parse('2026-05-01T00:00:00Z'));
  });

  it('is null when there are no parseable timestamps', () => {
    expect(newestRecordedAt([])).toBeNull();
    expect(newestRecordedAt([{ resourceID: 'a', reading: 1 }])).toBeNull();
  });
});
