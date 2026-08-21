import { describe, expect, it } from 'vitest';

import { expirationFromInput, futureDateInput } from './admin-format';

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
