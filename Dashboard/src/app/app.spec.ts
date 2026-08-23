import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { provideZonelessChangeDetection } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import { App } from './app';
import { INSIGHTS_CONFIG, defaultInsightsConfig } from './core/config';

describe('App shell', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [App],
      providers: [
        provideZonelessChangeDetection(),
        provideRouter([]),
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: INSIGHTS_CONFIG, useValue: defaultInsightsConfig },
      ],
    }).compileComponents();
  });

  async function render() {
    const fixture = TestBed.createComponent(App);
    await fixture.whenStable();
    return fixture.nativeElement as HTMLElement;
  }

  it('puts a skip link ahead of everything focusable', async () => {
    const root = await render();

    // It must be first, or a keyboard user traverses the whole navigation rail before reaching
    // the content on every single navigation.
    const skip = root.querySelector('a.ins-skip-link');
    expect(skip?.getAttribute('href')).toBe('#main');
    expect(root.querySelector('#main')).not.toBeNull();
  });

  it('leaves the page heading to the routed view', async () => {
    const root = await render();

    // The shell deliberately owns no h1: the heading should say what the page is about, not
    // repeat the product name on every route. The routed section supplies it.
    expect(root.querySelectorAll('h1')).toHaveLength(0);
  });
});
