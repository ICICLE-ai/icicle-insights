import type { Metric } from '../api/models';
import { parseTime } from '../../shared/format/formatters';

/** One point of a time series: epoch milliseconds and the value at that instant. */
export interface SeriesPoint {
  readonly time: number;
  readonly value: number;
}

/** The newest reading held for one resource. */
export interface LatestReading {
  readonly resourceID: string;
  readonly time: number;
  readonly value: number;
}

/**
 * Readings that carry everything the analytics need.
 *
 * Every field on `Metric` is optional because the Swift `toPublic()` projection omits anything a
 * query did not load. Narrowing once here means the rest of this file is not littered with
 * defensive checks, and a reading missing an id, value, or timestamp is dropped rather than
 * silently counted as zero at the epoch.
 */
type UsableMetric = Metric & { resourceID: string; reading: number; recordedAt: string };

function isUsable(metric: Metric): metric is UsableMetric {
  return (
    typeof metric.resourceID === 'string' &&
    typeof metric.reading === 'number' &&
    Number.isFinite(metric.reading) &&
    parseTime(metric.recordedAt) !== null
  );
}

/**
 * The portfolio total over time: at each reading's instant, the sum of every resource's most
 * recent reading at or before that moment.
 *
 * **Not** a sum grouped by timestamp. Resources are written at slightly different instants —
 * a bulk import spreads one sweep across many timestamps — so grouping would leave the final
 * timestamp holding only the handful of resources that happened to land in it, and the series
 * would collapse at its right-hand end. Carrying each resource's last known value forward is
 * what makes the total mean "everything we know about, as of then".
 *
 * Readings must therefore be processed in chronological order regardless of how they arrived.
 */
export function totalSeries(metrics: readonly Metric[]): SeriesPoint[] {
  const ordered = metrics
    .filter(isUsable)
    .map((metric) => ({ resourceID: metric.resourceID, value: metric.reading, time: parseTime(metric.recordedAt)! }))
    .sort((a, b) => a.time - b.time);

  const current = new Map<string, number>();
  // Keyed by timestamp so several resources written at the same instant collapse to one point,
  // holding the total after all of them are applied rather than one point per resource.
  const points = new Map<number, number>();

  let runningTotal = 0;
  for (const reading of ordered) {
    // Maintained incrementally rather than re-summing the map per reading, which turned the
    // whole pass quadratic in the number of readings.
    const previous = current.get(reading.resourceID);
    runningTotal += reading.value - (previous ?? 0);
    current.set(reading.resourceID, reading.value);
    points.set(reading.time, runningTotal);
  }

  return [...points.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([time, value]) => ({ time, value }));
}

/** The most recent value of the portfolio total, or zero when there are no usable readings. */
export function totalLatest(metrics: readonly Metric[]): number {
  const series = totalSeries(metrics);
  return series.length ? series[series.length - 1].value : 0;
}

/**
 * The newest reading per resource.
 *
 * "Newest" is resolved by timestamp rather than array position: the API returns oldest-first,
 * but merged slices and client-side filtering both disturb that, and trusting order would
 * quietly pick an older reading.
 */
export function latestByResource(metrics: readonly Metric[]): Map<string, LatestReading> {
  const best = new Map<string, LatestReading>();

  for (const metric of metrics) {
    if (!isUsable(metric)) {
      continue;
    }

    const time = parseTime(metric.recordedAt)!;
    const existing = best.get(metric.resourceID);
    if (!existing || time > existing.time) {
      best.set(metric.resourceID, { resourceID: metric.resourceID, time, value: metric.reading });
    }
  }

  return best;
}

/** Sums the newest reading of every resource — the current standing of one metric type. */
export function currentTotal(metrics: readonly Metric[]): number {
  let sum = 0;
  for (const latest of latestByResource(metrics).values()) {
    sum += latest.value;
  }
  return sum;
}

/** The most recent instant any of these readings was recorded, or null when there are none. */
export function newestRecordedAt(metrics: readonly Metric[]): number | null {
  let newest: number | null = null;

  for (const metric of metrics) {
    const time = parseTime(metric.recordedAt);
    if (time !== null && (newest === null || time > newest)) {
      newest = time;
    }
  }

  return newest;
}
