import { describe, expect, it } from 'vitest';

import { comparisonCadenceForSpan, relativeChange, rollingThirtyDayStart } from './trend-chart';

describe('rollingThirtyDayStart', () => {
  it('includes thirty UTC dates ending on the latest reading date', () => {
    const latest = Date.UTC(2026, 7, 20);

    expect(rollingThirtyDayStart(latest)).toBe(Date.UTC(2026, 6, 22));
  });
});

describe('comparisonCadenceForSpan', () => {
  it('keeps short comparisons daily and summarizes longer ranges', () => {
    expect(comparisonCadenceForSpan(30)).toBe('daily');
    expect(comparisonCadenceForSpan(100)).toBe('weekly');
    expect(comparisonCadenceForSpan(365)).toBe('monthly');
  });
});

describe('relativeChange', () => {
  it('uses a zero-percent baseline and preserves declines', () => {
    expect(relativeChange(100, 100)).toBe(0);
    expect(relativeChange(125, 100)).toBe(25);
    expect(relativeChange(75, 100)).toBe(-25);
  });

  it('does not divide by a missing or zero baseline', () => {
    expect(relativeChange(12, 0)).toBe(0);
  });
});
