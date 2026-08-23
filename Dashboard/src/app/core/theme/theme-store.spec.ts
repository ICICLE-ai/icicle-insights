import { provideZonelessChangeDetection } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { ThemeStore } from './theme-store';

describe('ThemeStore', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideZonelessChangeDetection()] });
  });

  it('follows the system by default', () => {
    // No stored choice means "follow the OS", not "light". The absence of the key is the signal,
    // which is why setPreference('system') removes it rather than writing the word.
    expect(TestBed.inject(ThemeStore).preference()).toBe('system');
  });

  it('resolves an explicit choice regardless of the system setting', () => {
    const store = TestBed.inject(ThemeStore);

    store.setPreference('dark');
    expect(store.preference()).toBe('dark');
    expect(store.isDark()).toBe(true);

    // The case a media query alone cannot express: the user wants light even where the OS is
    // dark. An explicit choice always outranks the system.
    store.setPreference('light');
    expect(store.preference()).toBe('light');
    expect(store.isDark()).toBe(false);
  });

  it('survives storage being unavailable', () => {
    // Partitioned frames and blocked cookies both make localStorage throw on access, and this
    // application is built to be embedded. Losing the preference is acceptable; throwing during
    // construction would take down the whole page.
    const store = TestBed.inject(ThemeStore);
    expect(() => store.setPreference('dark')).not.toThrow();
  });
});
