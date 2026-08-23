/**
 * Number and date formatting shared by tiles, axes, tables, and tooltips.
 *
 * Formatter instances are constructed once — `Intl.NumberFormat` is expensive enough that
 * rebuilding one per cell shows up on a table of a few hundred rows.
 */

/** Abbreviated form for axis ticks and tile values, e.g. `12.3K`. */
const compactFormatter = new Intl.NumberFormat('en', {
  notation: 'compact',
  maximumFractionDigits: 1,
});

/** Exact form for tooltips and tables, where the precise figure is the point. */
const wholeFormatter = new Intl.NumberFormat('en', { maximumFractionDigits: 0 });

const dateFormatter = new Intl.DateTimeFormat('en', {
  year: 'numeric',
  month: 'short',
  day: 'numeric',
});

/**
 * Abbreviated number.
 *
 * Negative zero is collapsed to zero first: axis ticks come out of floating-point arithmetic
 * that can produce `-0`, which `Intl` faithfully renders as "-0".
 */
export const compact = (value: number): string => compactFormatter.format(value === 0 ? 0 : value);

/** Exact number with thousands separators. */
export const whole = (value: number): string => wholeFormatter.format(value === 0 ? 0 : value);

/** Formats an ISO 8601 timestamp, returning an em dash for anything absent or unparseable. */
export function formatDate(iso: string | undefined | null): string {
  if (!iso) {
    return '—';
  }

  const time = Date.parse(iso);
  return Number.isFinite(time) ? dateFormatter.format(time) : '—';
}

/**
 * Parses an ISO 8601 timestamp to epoch milliseconds, or null when absent or unparseable.
 *
 * Returning null rather than NaN forces callers to handle the missing case: NaN propagates
 * silently through comparisons and arithmetic, and a NaN timestamp sorts unpredictably rather
 * than failing.
 */
export function parseTime(iso: string | undefined | null): number | null {
  if (!iso) {
    return null;
  }

  const time = Date.parse(iso);
  return Number.isFinite(time) ? time : null;
}

/**
 * Whole days from `now` until `iso`; negative once past. Null when the date is unusable.
 *
 * Used for expiry runway on vaults and service tokens, where the sign is what decides whether
 * something is a warning or an incident.
 */
export function daysUntil(iso: string | undefined | null, now: number): number | null {
  const time = parseTime(iso);
  if (time === null) {
    return null;
  }

  return Math.floor((time - now) / 86_400_000);
}

/** Pluralises a count with its noun, e.g. `1 resource` / `3 resources`. */
export const pluralize = (count: number, singular: string, plural = `${singular}s`): string =>
  `${whole(count)} ${count === 1 ? singular : plural}`;
