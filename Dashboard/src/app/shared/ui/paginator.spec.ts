import { describe, expect, it } from 'vitest';

import { DEFAULT_PAGE_SIZE, pageSlice } from './paginator';

const rows = Array.from({ length: 25 }, (_, i) => i);

describe('pageSlice', () => {
  it('returns the rows belonging to the requested page', () => {
    expect(pageSlice(rows, 0, 10)).toStrictEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(pageSlice(rows, 1, 10)).toStrictEqual([10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);
  });

  it('returns a short final page rather than padding it', () => {
    expect(pageSlice(rows, 2, 10)).toStrictEqual([20, 21, 22, 23, 24]);
  });

  it('clamps past the end to the last page that exists', () => {
    // The case that matters: filtering a table while parked on a high page must land on real
    // rows, not on an empty body under a pager that still reads "Page 1 of 1".
    expect(pageSlice(rows, 99, 10)).toStrictEqual([20, 21, 22, 23, 24]);
  });

  it('clamps a negative page to the first', () => {
    expect(pageSlice(rows, -3, 10)).toStrictEqual(pageSlice(rows, 0, 10));
  });

  it('is empty for no rows, at any page', () => {
    expect(pageSlice([], 0, 10)).toStrictEqual([]);
    expect(pageSlice([], 4, 10)).toStrictEqual([]);
  });

  it('defaults to the same page size the paginator input does', () => {
    expect(pageSlice(rows, 0)).toStrictEqual(pageSlice(rows, 0, DEFAULT_PAGE_SIZE));
    expect(pageSlice(rows, 0)).toHaveLength(DEFAULT_PAGE_SIZE);
  });

  it('agrees with the pager on how many pages there are', () => {
    // Both sides derive the last page the same way; if they ever diverge, a table shows a page
    // number with nothing under it.
    const pageSize = 8;
    const pages = Math.ceil(rows.length / pageSize);
    const lastPage = pages - 1;
    expect(pageSlice(rows, lastPage, pageSize).length).toBeGreaterThan(0);
    expect(pageSlice(rows, lastPage, pageSize)).toStrictEqual(
      pageSlice(rows, lastPage + 5, pageSize),
    );
  });
});
