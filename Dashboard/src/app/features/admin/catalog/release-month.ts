/**
 * Calendar-month picker values for the release editor.
 *
 * Split out from the component because these are the parts with edge cases worth testing
 * directly: the range union for out-of-range history, and the UTC read that keeps a release
 * recorded on the first of a month from sliding into the previous one.
 */

/** Inclusive year range offered by the pickers. Nothing in the live catalog predates the first. */
export const FIRST_RELEASE_YEAR = 2023;
export const LAST_RELEASE_YEAR = 2028;

/** Month values and names, in calendar order. Values are the two-digit form the API expects. */
export const MONTH_OPTIONS: readonly { readonly value: string; readonly label: string }[] = [
  { value: '01', label: 'January' },
  { value: '02', label: 'February' },
  { value: '03', label: 'March' },
  { value: '04', label: 'April' },
  { value: '05', label: 'May' },
  { value: '06', label: 'June' },
  { value: '07', label: 'July' },
  { value: '08', label: 'August' },
  { value: '09', label: 'September' },
  { value: '10', label: 'October' },
  { value: '11', label: 'November' },
  { value: '12', label: 'December' },
];

/** A release's year and month as picker values. */
export interface YearMonth {
  readonly year: string;
  readonly month: string;
}

/**
 * Year values for a picker: the fixed range, plus `extra` when it falls outside it.
 *
 * A `<select>` bound to a value with no matching option renders blank, so editing a release
 * dated before 2023 — the seeded ICICLE history is — would silently offer to move it into
 * range. Including its own year keeps the edit honest.
 *
 * Sorted numerically rather than lexically: four-digit strings happen to agree today, but only
 * until someone widens the range.
 */
export function releaseYearOptions(extra?: string): readonly string[] {
  const years = new Set<string>();
  for (let year = FIRST_RELEASE_YEAR; year <= LAST_RELEASE_YEAR; year += 1) {
    years.add(String(year));
  }
  if (extra && /^\d{4}$/u.test(extra)) {
    years.add(extra);
  }
  return [...years].sort((a, b) => Number(a) - Number(b));
}

/** Today's year and month as picker values, with the year clamped into the offered range. */
export function currentYearMonth(now: Date = new Date()): YearMonth {
  const year = Math.min(Math.max(now.getFullYear(), FIRST_RELEASE_YEAR), LAST_RELEASE_YEAR);
  return { year: String(year), month: String(now.getMonth() + 1).padStart(2, '0') };
}

/**
 * Splits an ISO release date into picker values, falling back to today when unparsable.
 *
 * Read in UTC, matching how `releasedAt` is stored: reading it locally flips a release recorded
 * at midnight on the first of a month back into the previous one anywhere west of Greenwich.
 */
export function toYearMonth(value: string | undefined, now: Date = new Date()): YearMonth {
  const time = Date.parse(value ?? '');
  if (!Number.isFinite(time)) {
    return currentYearMonth(now);
  }

  const date = new Date(time);
  return {
    year: String(date.getUTCFullYear()),
    month: String(date.getUTCMonth() + 1).padStart(2, '0'),
  };
}
