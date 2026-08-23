import { describe, expect, it } from 'vitest';

import {
  FIRST_RELEASE_YEAR,
  LAST_RELEASE_YEAR,
  MONTH_OPTIONS,
  currentYearMonth,
  releaseYearOptions,
  toYearMonth,
} from './release-month';

describe('releaseYearOptions', () => {
  it('offers every year in the configured range', () => {
    const years = releaseYearOptions();
    expect(years[0]).toBe(String(FIRST_RELEASE_YEAR));
    expect(years.at(-1)).toBe(String(LAST_RELEASE_YEAR));
    expect(years).toHaveLength(LAST_RELEASE_YEAR - FIRST_RELEASE_YEAR + 1);
  });

  it('adds a year outside the range and keeps the list ordered', () => {
    // Editing a release from the seeded ICICLE history must not silently move it into range.
    const years = releaseYearOptions('2019');
    expect(years).toContain('2019');
    expect(years[0]).toBe('2019');
    expect(years.map(Number)).toStrictEqual([...years].map(Number).sort((a, b) => a - b));
  });

  it('does not duplicate a year already inside the range', () => {
    const years = releaseYearOptions('2024');
    expect(years.filter((year) => year === '2024')).toHaveLength(1);
  });

  it('ignores an extra that is not a four-digit year', () => {
    expect(releaseYearOptions('')).toStrictEqual(releaseYearOptions());
    expect(releaseYearOptions('not-a-year')).toStrictEqual(releaseYearOptions());
  });
});

describe('MONTH_OPTIONS', () => {
  it('carries twelve zero-padded values in calendar order', () => {
    expect(MONTH_OPTIONS).toHaveLength(12);
    expect(MONTH_OPTIONS.map((month) => month.value)).toStrictEqual([
      '01',
      '02',
      '03',
      '04',
      '05',
      '06',
      '07',
      '08',
      '09',
      '10',
      '11',
      '12',
    ]);
  });
});

describe('toYearMonth', () => {
  it('reads the stored date in UTC', () => {
    // Midnight UTC on the first: read locally anywhere west of Greenwich this is the 31st of
    // the previous month, which would file the release under the wrong month.
    expect(toYearMonth('2026-03-01T00:00:00Z')).toStrictEqual({ year: '2026', month: '03' });
    expect(toYearMonth('2026-12-31T23:59:59Z')).toStrictEqual({ year: '2026', month: '12' });
  });

  it('zero-pads single-digit months', () => {
    expect(toYearMonth('2025-07-15T12:00:00Z').month).toBe('07');
  });

  it('preserves a year outside the offered range rather than clamping it', () => {
    expect(toYearMonth('2019-05-01T00:00:00Z')).toStrictEqual({ year: '2019', month: '05' });
  });

  it('falls back to today for a missing or unparsable date', () => {
    const now = new Date('2026-04-09T00:00:00Z');
    expect(toYearMonth(undefined, now)).toStrictEqual(currentYearMonth(now));
    expect(toYearMonth('not a date', now)).toStrictEqual(currentYearMonth(now));
  });
});

describe('currentYearMonth', () => {
  it('clamps a year past the end of the range', () => {
    expect(currentYearMonth(new Date('2031-06-15T12:00:00Z')).year).toBe(String(LAST_RELEASE_YEAR));
  });

  it('clamps a year before the start of the range', () => {
    expect(currentYearMonth(new Date('2001-06-15T12:00:00Z')).year).toBe(
      String(FIRST_RELEASE_YEAR),
    );
  });

  it('always names a month the picker offers', () => {
    const values = MONTH_OPTIONS.map((month) => month.value);
    expect(values).toContain(currentYearMonth().month);
  });
});
