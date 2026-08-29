import { DOCUMENT, Service, computed, inject } from '@angular/core';

import type { Platform } from '../../core/api/models';
import { PLATFORM_ORDER } from '../format/labels';
import { ThemeStore } from '../../core/theme/theme-store';

/** Concrete colours for one theme, resolved from the CSS custom properties in styles.css. */
export interface ChartPalette {
  readonly series: readonly string[];
  readonly ranked: readonly string[];
  readonly rankedInk: string;
  readonly ink: string;
  readonly inkSecondary: string;
  readonly muted: string;
  readonly grid: string;
  readonly axis: string;
  readonly surface: string;
  /**
   * Registry identity colours, keyed by platform.
   *
   * Separate from `series` because a registry's colour follows the registry, not its rank in
   * whatever chart is on screen — the same npm that is a bar in the scope picker must be the same
   * hue as the npm slice in a donut beside it.
   */
  readonly platforms: Readonly<Record<Platform, string>>;
}

/** Names of the eight categorical slots, in the fixed order the ramp was validated in. */
const SERIES_TOKENS = [
  '--ins-series-1',
  '--ins-series-2',
  '--ins-series-3',
  '--ins-series-4',
  '--ins-series-5',
  '--ins-series-6',
  '--ins-series-7',
  '--ins-series-8',
];

/** Five presentation colours for ranked bars with labels drawn inside their fills. */
const RANKED_TOKENS = [
  '--ins-rank-1',
  '--ins-rank-2',
  '--ins-rank-3',
  '--ins-rank-4',
  '--ins-rank-5',
];

/**
 * Fallbacks used when the document has no computed style to read.
 *
 * Only reached under a non-browser test renderer. They are the light steps, so a chart built in
 * that setting is still coloured correctly rather than painted with empty strings, which SVG
 * renders as black on black.
 */
const FALLBACK: ChartPalette = {
  series: ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#4a3aa7', '#e34948'],
  ranked: ['#3a78d4', '#dc6b3c', '#249a73', '#7856c8', '#d14f82'],
  rankedInk: '#ffffff',
  ink: '#0b0b0b',
  inkSecondary: '#52514e',
  muted: '#898781',
  grid: '#e1e0d9',
  axis: '#c3c2b7',
  surface: '#fcfcfb',
  platforms: {
    github: '#1baf7a',
    ghcr: '#4a3aa7',
    huggingface: '#eda100',
    npm: '#e87ba4',
    pypi: '#2a78d6',
    patra: '#b10fbd',
  },
};

/**
 * Resolves the design tokens into the literal colour strings the chart runtime needs.
 *
 * Charts are handed concrete values rather than `var(--…)` references. A CSS variable inside an
 * SVG presentation attribute does resolve in current browsers, but it also means the exported
 * SVG carries references to properties that do not exist outside this page — and the chart
 * runtime cannot reason about a colour it cannot read. Resolving here keeps one source of truth
 * in `styles.css` while giving the charts real values.
 *
 * The result depends on `ThemeStore.isDark()`, so every definition built from it is rebuilt when
 * the theme flips — which is what makes charts follow the toggle without their own listener.
 */
@Service()
export class ChartPaletteService {
  private readonly document = inject(DOCUMENT);
  private readonly theme = inject(ThemeStore);

  readonly palette = computed<ChartPalette>(() => {
    // Read so the computation re-runs on a theme change. The class is already on the element by
    // the time this runs, because ThemeStore's effect applies it.
    this.theme.isDark();

    const view = this.document.defaultView;
    if (!view) {
      return FALLBACK;
    }

    const styles = view.getComputedStyle(this.document.documentElement);
    const read = (token: string, fallback: string): string =>
      styles.getPropertyValue(token).trim() || fallback;

    return {
      series: SERIES_TOKENS.map((token, i) => read(token, FALLBACK.series[i])),
      ranked: RANKED_TOKENS.map((token, i) => read(token, FALLBACK.ranked[i])),
      rankedInk: read('--ins-rank-ink', FALLBACK.rankedInk),
      ink: read('--ins-ink', FALLBACK.ink),
      inkSecondary: read('--ins-ink-secondary', FALLBACK.inkSecondary),
      muted: read('--ins-ink-muted', FALLBACK.muted),
      grid: read('--ins-grid', FALLBACK.grid),
      axis: read('--ins-axis', FALLBACK.axis),
      surface: read('--ins-surface', FALLBACK.surface),
      platforms: Object.fromEntries(
        PLATFORM_ORDER.map((platform) => [
          platform,
          read(`--ins-platform-${platform}`, FALLBACK.platforms[platform]),
        ]),
      ) as Readonly<Record<Platform, string>>,
    };
  });
}
