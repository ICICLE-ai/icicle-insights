import { describe, expect, it } from 'vitest';

import { expirationFromInput, formatAdminMonth, futureDateInput } from './admin-format';

describe('admin date inputs', () => {
  it('maps a native date value to the Vault calendar shape', () => {
    expect(expirationFromInput('2030-12-31')).toEqual({ year: 2030, month: 12, day: 31 });
  });

  it('rejects malformed and impossible calendar dates', () => {
    expect(expirationFromInput('2030-02-30')).toBeNull();
    expect(expirationFromInput('12/31/2030')).toBeNull();
  });

  it('produces UTC-stable defaults for date controls', () => {
    expect(futureDateInput(2, Date.UTC(2026, 7, 20, 23, 30))).toBe('2026-08-22');
  });
});

describe('formatAdminMonth', () => {
  it('reads a month-anchored date in UTC, not the reader local zone', () => {
    // Releases are stored as the first instant of their month. Read locally, anywhere behind
    // UTC this is March 31 — which displayed every release a month early.
    expect(formatAdminMonth('2023-04-01T00:00:00Z')).toBe('April 2023');
    expect(formatAdminMonth('2026-01-01T00:00:00Z')).toBe('January 2026');
  });

  it('shows no day, because the stored one carries no meaning', () => {
    expect(formatAdminMonth('2023-04-01T00:00:00Z')).not.toMatch(/\d{1,2},/u);
  });

  it('matches formatAdminDate on missing and malformed input', () => {
    expect(formatAdminMonth(undefined)).toBe('Not set');
    expect(formatAdminMonth('not a date')).toBe('Not set');
  });
});
