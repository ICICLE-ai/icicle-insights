import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { provideZonelessChangeDetection, signal, type WritableSignal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import { INSIGHTS_CONFIG, defaultInsightsConfig } from '../../core/config';
import { SessionStore } from '../../core/auth/session-store';
import { AppNav } from './app-nav';

describe('AppNav', () => {
  let isAdmin: WritableSignal<boolean>;
  let username: WritableSignal<string | null>;

  beforeEach(async () => {
    isAdmin = signal(false);
    username = signal(null);

    await TestBed.configureTestingModule({
      imports: [AppNav],
      providers: [
        provideZonelessChangeDetection(),
        provideRouter([]),
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: INSIGHTS_CONFIG, useValue: defaultInsightsConfig },
        { provide: SessionStore, useValue: { isAdmin, username } },
      ],
    }).compileComponents();
  });

  async function render(): Promise<HTMLElement> {
    const fixture = TestBed.createComponent(AppNav);
    await fixture.whenStable();
    return fixture.nativeElement as HTMLElement;
  }

  it('keeps admin navigation out of the public experience', async () => {
    const root = await render();
    expect(root.querySelector('nav')).toBeNull();
    expect(root.querySelector('.ins-nav__admin')).toBeNull();
  });

  it('shows the theme control as a standalone public control', async () => {
    const root = await render();
    const theme = root.querySelector('.ins-nav__theme');

    expect(theme?.querySelector('app-theme-picker')).not.toBeNull();
    expect(theme?.querySelector('button')).not.toBeNull();
    expect(theme?.closest('.ins-nav__admin')).toBeNull();
  });

  it('keeps the product name visible without making the brand a disclosure', async () => {
    const root = await render();
    const brand = root.querySelector('.ins-nav__brand');

    expect(brand?.textContent).toContain('ICICLE Insights');
    expect(brand?.matches('button')).toBe(false);
    expect(root.querySelector('.ins-nav__trigger')).toBeNull();
    expect(root.textContent).not.toContain('Public');
  });

  it('shows admin destinations immediately after admin status is confirmed', async () => {
    isAdmin.set(true);
    username.set('cguz109');

    const root = await render();
    const nav = root.querySelector('nav');

    expect(nav?.getAttribute('aria-label')).toBe('Primary');
    expect(nav?.textContent).toContain('Overview');
    expect(nav?.textContent).toContain('Administration');
    expect(root.querySelector('.ins-nav__identity')?.textContent).toContain('cguz109');
    expect(root.querySelector('.ins-nav__trigger')).toBeNull();
  });
});
