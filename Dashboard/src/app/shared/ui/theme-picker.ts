import { Component, ElementRef, computed, inject, signal, viewChild } from '@angular/core';

import { ThemeStore, type ThemePreference } from '../../core/theme/theme-store';

interface ThemeOption {
  readonly value: ThemePreference;
  readonly label: string;
  readonly glyph: string;
}

const OPTIONS: readonly ThemeOption[] = [
  { value: 'light', label: 'Light', glyph: '☀' },
  { value: 'dark', label: 'Dark', glyph: '☾' },
  { value: 'system', label: 'System', glyph: '◐' },
];

/**
 * Chooses the colour scheme, as an icon that flies out into its three options.
 *
 * Collapsed, the button wears the icon of whatever is currently in force, so the control states
 * the setting instead of merely offering to change it — the flaw in the toggle this replaced,
 * which read "Dark mode" whichever way it was set.
 *
 * The options are still native radios in a fieldset even though they look like a small stack of
 * icons. That is what supplies arrow-key navigation, roving focus, and group semantics; a set of
 * icon buttons would have to reimplement all three and would report itself as three unrelated
 * controls. Each keeps a visible-to-assistive-tech label, since an icon alone names nothing.
 */
@Component({
  selector: 'app-theme-picker',
  host: {
    '(keydown.escape)': 'closeAndRestoreFocus()',
    '(document:pointerdown)': 'onDocumentPointerDown($event)',
  },
  template: `
    <div class="ins-theme">
      <button
        #trigger
        type="button"
        class="ins-theme__trigger"
        [attr.aria-expanded]="isOpen()"
        aria-controls="theme-options"
        [title]="currentLabel()"
        (click)="toggle()"
      >
        <span aria-hidden="true">{{ currentGlyph() }}</span>
        <span class="ins-visually-hidden">Theme: {{ currentLabel() }}</span>
      </button>

      <fieldset id="theme-options" class="ins-theme__options" [hidden]="!isOpen()">
        <legend class="ins-visually-hidden">Colour theme</legend>

        @for (option of options; track option.value) {
          <label
            class="ins-theme__option"
            [class.is-selected]="theme.preference() === option.value"
            [title]="option.label"
          >
            <input
              class="ins-theme__input"
              type="radio"
              name="theme"
              [checked]="theme.preference() === option.value"
              (change)="choose(option.value)"
            />
            <span aria-hidden="true">{{ option.glyph }}</span>
            <span class="ins-visually-hidden">{{ option.label }}</span>
          </label>
        }
      </fieldset>
    </div>

    <!-- Announces the outcome on change. Necessary for "System", whose result is not derivable
         from the control's own label. -->
    <p class="ins-visually-hidden" role="status" aria-live="polite">{{ resolved() }}</p>
  `,
  styles: `
    .ins-theme {
      position: relative;
      display: inline-flex;
    }

    .ins-theme__trigger {
      display: grid;
      place-items: center;
      width: 2rem;
      height: 2rem;
      font: inherit;
      font-size: 0.9375rem;
      color: var(--ins-ink-secondary);
      background: transparent;
      border: 1px solid transparent;
      border-radius: 50%;
      cursor: pointer;
    }

    .ins-theme__trigger:hover,
    .ins-theme__trigger[aria-expanded='true'] {
      color: var(--ins-ink);
      background: var(--ins-raised);
      border-color: var(--ins-border);
    }

    /* Drops straight down from the trigger, centred on it. The connecting rule is what ties the
       stack back to the control it belongs to, so the options do not read as a floating group. */
    .ins-theme__options {
      position: absolute;
      top: calc(100% + 0.375rem);
      left: 50%;
      transform: translateX(-50%);
      z-index: 1;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.25rem;
      margin: 0;
      padding: 0.375rem 0.25rem;
      border: 1px solid var(--ins-border-strong);
      border-radius: 999px;
      background: var(--ins-surface);
      box-shadow: 0 4px 12px rgb(11 15 20 / 12%);
    }

    .ins-theme__options[hidden] {
      display: none;
    }

    .ins-theme__option {
      display: grid;
      place-items: center;
      width: 1.75rem;
      height: 1.75rem;
      font-size: 0.875rem;
      color: var(--ins-ink-muted);
      border-radius: 50%;
      cursor: pointer;
    }

    .ins-theme__option:hover {
      color: var(--ins-ink);
      background: var(--ins-raised);
    }

    /* Selection carried by fill and ink together, never by colour alone. */
    .ins-theme__option.is-selected {
      color: #ffffff;
      background: var(--ins-series-1);
    }

    /* Clipped rather than display:none, which would take the radio out of the accessibility tree
       and remove keyboard access with it. */
    .ins-theme__input {
      position: absolute;
      width: 1px;
      height: 1px;
      opacity: 0;
      pointer-events: none;
    }

    .ins-theme__input:focus-visible + span {
      outline: 2px solid var(--ins-series-1);
      outline-offset: 3px;
      border-radius: 2px;
    }
  `,
})
export class ThemePicker {
  protected readonly theme = inject(ThemeStore);
  protected readonly options = OPTIONS;

  private readonly host = inject(ElementRef<HTMLElement>);
  private readonly trigger = viewChild<ElementRef<HTMLButtonElement>>('trigger');
  private readonly open = signal(false);

  protected readonly isOpen = this.open.asReadonly();

  /** The trigger wears the chosen mode's icon, so the control shows its own state. */
  protected readonly currentGlyph = computed(
    () => OPTIONS.find((o) => o.value === this.theme.preference())?.glyph ?? '◐',
  );

  protected readonly currentLabel = computed(() => {
    const preference = this.theme.preference();
    if (preference !== 'system') {
      return preference === 'dark' ? 'Dark' : 'Light';
    }
    return `System (currently ${this.theme.isDark() ? 'dark' : 'light'})`;
  });

  protected readonly resolved = computed(() => {
    const scheme = this.theme.isDark() ? 'dark' : 'light';
    return this.theme.preference() === 'system'
      ? `Theme follows your system setting, currently ${scheme}.`
      : `Theme set to ${scheme}.`;
  });

  protected toggle(): void {
    this.open.update((value) => !value);
  }

  /** Applies a choice and closes, since the flyout has served its purpose. */
  protected choose(preference: ThemePreference): void {
    this.theme.setPreference(preference);
    this.open.set(false);
    this.trigger()?.nativeElement.focus();
  }

  /**
   * Closes and returns focus to the trigger.
   *
   * Without restoring focus, Escape drops it to the document root and the next Tab restarts from
   * the top of the page rather than from the control just used.
   */
  protected closeAndRestoreFocus(): void {
    if (!this.open()) {
      return;
    }

    this.open.set(false);
    this.trigger()?.nativeElement.focus();
  }

  /** Closes on a press outside. Focus is left alone — the press is already moving it. */
  protected onDocumentPointerDown(event: PointerEvent): void {
    if (this.open() && !this.host.nativeElement.contains(event.target as Node)) {
      this.open.set(false);
    }
  }
}
