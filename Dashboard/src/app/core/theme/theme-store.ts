import { DOCUMENT, Service, computed, effect, inject, signal } from '@angular/core';

/** What the user asked for, which is not the same as what is being displayed. */
export type ThemePreference = 'system' | 'light' | 'dark';

const STORAGE_KEY = 'insights-theme';

/** Must stay in step with `darkModeSelector` in app.config.ts and the `dark` variant in styles.css. */
const DARK_CLASS = 'app-dark';

/**
 * Owns the light/dark preference and reflects it onto the document element.
 *
 * Three states rather than a boolean: "system" has to be distinguishable from an explicit
 * choice, or a user who picks light while their OS is dark gets overridden the next time the OS
 * setting is consulted. Only the resolved result reaches CSS — one class, which Optimus, the
 * Tailwind `dark` variant, and the chart tokens all key off, so they can never disagree.
 *
 * The same resolution runs inline in index.html before first paint. This class takes over
 * afterwards; the duplication is deliberate, since deferring it to Angular would paint the light
 * palette first and swap, which reads as a flash on every load.
 */
@Service()
export class ThemeStore {
  private readonly document = inject(DOCUMENT);

  private readonly systemPrefersDark = signal(false);
  private readonly preferenceState = signal<ThemePreference>(this.readStoredPreference());

  /** The user's choice: system, light, or dark. */
  readonly preference = this.preferenceState.asReadonly();

  /** What is actually on screen, after resolving "system". */
  readonly isDark = computed(() =>
    this.preferenceState() === 'system'
      ? this.systemPrefersDark()
      : this.preferenceState() === 'dark',
  );

  constructor() {
    this.watchSystemPreference();

    effect(() => {
      this.document.documentElement.classList.toggle(DARK_CLASS, this.isDark());
    });
  }

  /**
   * Records a preference and persists it.
   *
   * Persisting "system" writes nothing and clears any stored value, so the absence of a key
   * means "follow the OS" — which is also what index.html assumes on a first visit.
   */
  setPreference(preference: ThemePreference): void {
    this.preferenceState.set(preference);

    try {
      if (preference === 'system') {
        localStorage.removeItem(STORAGE_KEY);
      } else {
        localStorage.setItem(STORAGE_KEY, preference);
      }
    } catch {
      // Storage is unavailable in a partitioned frame or with cookies blocked, both of which are
      // ordinary when embedded. The preference still applies to this session; it just will not
      // survive a reload, which is a cosmetic loss rather than a broken page.
    }
  }

  /** Flips between light and dark, resolving "system" to whatever is currently displayed. */
  toggle(): void {
    this.setPreference(this.isDark() ? 'light' : 'dark');
  }

  private readStoredPreference(): ThemePreference {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      return stored === 'dark' || stored === 'light' ? stored : 'system';
    } catch {
      return 'system';
    }
  }

  /**
   * Tracks the OS setting so a "system" preference follows a change made while the tab is open.
   *
   * The listener stays registered whatever the preference is: the value is only *read* when the
   * preference resolves to system, and tearing it down and rebuilding it on every preference
   * change would be more moving parts for no benefit.
   */
  private watchSystemPreference(): void {
    const view = this.document.defaultView;
    if (!view?.matchMedia) {
      return;
    }

    const query = view.matchMedia('(prefers-color-scheme: dark)');
    this.systemPrefersDark.set(query.matches);
    query.addEventListener('change', (event) => this.systemPrefersDark.set(event.matches));
  }
}
