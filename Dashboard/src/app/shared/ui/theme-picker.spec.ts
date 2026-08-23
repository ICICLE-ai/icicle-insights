import { provideZonelessChangeDetection } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { ThemeStore } from '../../core/theme/theme-store';
import { ThemePicker } from './theme-picker';

describe('ThemePicker', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ThemePicker],
      providers: [provideZonelessChangeDetection()],
    }).compileComponents();
  });

  async function render() {
    const fixture = TestBed.createComponent(ThemePicker);
    await fixture.whenStable();
    return fixture;
  }

  it('offers all three states, not a two-way toggle', async () => {
    const fixture = await render();
    const labels = [...(fixture.nativeElement as HTMLElement).querySelectorAll('label')].map(
      (label) => label.textContent?.trim(),
    );

    expect(labels.some((l) => l?.includes('Light'))).toBe(true);
    expect(labels.some((l) => l?.includes('Dark'))).toBe(true);
    expect(labels.some((l) => l?.includes('System'))).toBe(true);
  });

  it('uses native radios so the group gets keyboard semantics for free', async () => {
    const fixture = await render();
    const inputs = (fixture.nativeElement as HTMLElement).querySelectorAll<HTMLInputElement>(
      'input[type="radio"]',
    );

    expect(inputs).toHaveLength(3);
    // One shared name is what makes them a single roving-focus group rather than three
    // independent controls.
    expect(new Set([...inputs].map((input) => input.name)).size).toBe(1);
  });

  it('marks exactly one option selected, and moves that mark when the choice changes', async () => {
    const fixture = await render();
    const store = TestBed.inject(ThemeStore);
    const root = fixture.nativeElement as HTMLElement;

    const selected = () =>
      [...root.querySelectorAll('label.is-selected')].map((el) => el.textContent?.trim() ?? '');

    store.setPreference('dark');
    await fixture.whenStable();
    expect(selected()).toHaveLength(1);
    expect(selected()[0]).toContain('Dark');

    // The regression this guards: the control it replaced kept one fixed label whatever the
    // state, so the visible mark never moved.
    store.setPreference('light');
    await fixture.whenStable();
    expect(selected()).toHaveLength(1);
    expect(selected()[0]).toContain('Light');
  });

  it('states the resolved scheme when following the system', async () => {
    const fixture = await render();
    const store = TestBed.inject(ThemeStore);

    store.setPreference('system');
    await fixture.whenStable();

    // "System" alone does not tell anyone what they are looking at, so the live region names
    // the scheme it resolved to.
    const status = (fixture.nativeElement as HTMLElement).querySelector('[role="status"]');
    expect(status?.textContent).toContain('follows your system setting');
    expect(status?.textContent).toMatch(/currently (light|dark)/);
  });
});
