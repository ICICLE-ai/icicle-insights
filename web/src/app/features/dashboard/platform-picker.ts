import { Component, ElementRef, computed, inject, signal, viewChild } from '@angular/core';

import { pluralize, whole } from '../../shared/format/formatters';
import { platformColor, platformScopes, type PlatformFilter } from '../../shared/format/labels';
import { DashboardStore } from './dashboard-store';

interface PlatformOption {
  readonly value: PlatformFilter;
  readonly label: string;
  readonly description: string | null;
  readonly count: number;
  readonly share: number;
  readonly color: string;
}

/**
 * Compact registry scope disclosure.
 *
 * The closed button states the current scope. Opening reveals the former rail's analytical
 * context—counts and proportional bars—but vertically, so it remains useful without reserving a
 * full dashboard row.
 */
@Component({
  selector: 'app-platform-picker',
  host: {
    '(keydown.escape)': 'closeAndRestoreFocus()',
    '(document:pointerdown)': 'onDocumentPointerDown($event)',
  },
  template: `
    <div class="ins-platform-picker">
      <button
        #trigger
        type="button"
        class="ins-platform-picker__trigger"
        aria-controls="platform-options"
        [attr.aria-expanded]="isOpen()"
        (click)="toggle()"
      >
        <span class="ins-platform-picker__trigger-copy">
          <span class="ins-platform-picker__trigger-label">{{ selected().label }}</span>
          <span class="ins-platform-picker__trigger-count ins-mono">
            {{ resourceCount(selected().count) }}
          </span>
        </span>
        <span class="ins-platform-picker__chevron" aria-hidden="true">
          {{ isOpen() ? '⌃' : '⌄' }}
        </span>
        <span class="ins-platform-picker__track" aria-hidden="true">
          <span
            class="ins-platform-picker__bar"
            [style.width.%]="selected().share"
            [style.background]="selected().color"
          ></span>
        </span>
      </button>

      <div id="platform-options" class="ins-platform-picker__panel" [hidden]="!isOpen()">
        <fieldset>
          <legend class="ins-visually-hidden">Choose a registry or registry group</legend>

          @for (option of options(); track option.value) {
            <label class="ins-platform-picker__option" [class.is-selected]="isSelected(option)">
              <input
                class="ins-platform-picker__input"
                type="radio"
                name="platform-scope"
                [checked]="isSelected(option)"
                (change)="select(option)"
              />
              <span class="ins-platform-picker__option-copy">
                <span class="ins-platform-picker__option-identity">
                  <span class="ins-platform-picker__option-name">{{ option.label }}</span>
                  @if (option.description) {
                    <span class="ins-platform-picker__option-description">
                      {{ option.description }}
                    </span>
                  }
                </span>
                <span class="ins-platform-picker__option-count ins-mono">
                  {{ exact(option.count) }}
                </span>
              </span>
              <span class="ins-platform-picker__track" aria-hidden="true">
                <span
                  class="ins-platform-picker__bar"
                  [style.width.%]="option.share"
                  [style.background]="option.color"
                ></span>
              </span>
              <span class="ins-visually-hidden">
                {{ resourceCount(option.count) }}
              </span>
            </label>
          }
        </fieldset>
      </div>
    </div>
  `,
  styles: `
    :host {
      display: block;
    }

    .ins-platform-picker {
      position: relative;
      width: min(19rem, 42vw);
    }

    .ins-platform-picker__trigger {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 0.375rem 0.75rem;
      width: 100%;
      height: var(--ins-masthead-height);
      min-height: var(--ins-masthead-height);
      box-sizing: border-box;
      padding: 0.5rem 0.75rem;
      font: inherit;
      color: var(--ins-ink);
      text-align: left;
      background: var(--ins-raised);
      border: 1px solid var(--ins-border-strong);
      border-radius: var(--ins-radius);
      cursor: pointer;
      transition:
        border-color 120ms ease,
        background 120ms ease;
    }

    .ins-platform-picker__trigger:hover,
    .ins-platform-picker__trigger[aria-expanded='true'] {
      background: var(--ins-surface);
      border-color: var(--ins-series-1);
    }

    .ins-platform-picker__trigger-copy {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 0.75rem;
      min-width: 0;
    }

    .ins-platform-picker__trigger-label {
      overflow: hidden;
      font-size: var(--ins-text-small);
      font-weight: 650;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .ins-platform-picker__trigger-count {
      flex: none;
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
    }

    .ins-platform-picker__chevron {
      align-self: center;
      color: var(--ins-ink-muted);
      font-size: 1rem;
      line-height: 1;
    }

    .ins-platform-picker__track {
      display: block;
      grid-column: 1 / -1;
      height: 4px;
      overflow: hidden;
      background: var(--ins-grid);
      border-radius: 999px;
    }

    .ins-platform-picker__bar {
      display: block;
      height: 100%;
      border-radius: inherit;
    }

    .ins-platform-picker__panel {
      position: absolute;
      top: calc(100% + 0.5rem);
      left: 0;
      z-index: 10;
      width: min(21rem, calc(100vw - 3rem));
      max-height: min(28rem, calc(100vh - 8rem));
      padding: 0.5rem;
      overflow-y: auto;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border-strong);
      border-radius: var(--ins-radius);
      box-shadow: 0 14px 36px rgb(11 15 20 / 14%);
    }

    .ins-platform-picker__panel[hidden] {
      display: none;
    }

    .ins-platform-picker__panel fieldset {
      display: grid;
      gap: 0.375rem;
      margin: 0;
      padding: 0;
      border: 0;
    }

    .ins-platform-picker__option {
      position: relative;
      display: grid;
      gap: 0.5rem;
      min-height: 3.5rem;
      padding: 0.625rem 0.75rem;
      color: var(--ins-ink-secondary);
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
      cursor: pointer;
    }

    .ins-platform-picker__option:hover {
      color: var(--ins-ink);
      border-color: var(--ins-border-strong);
      background: var(--ins-raised);
    }

    .ins-platform-picker__option.is-selected {
      color: var(--ins-ink);
      border-color: var(--ins-ink);
      background: var(--ins-raised);
    }

    .ins-platform-picker__input {
      position: absolute;
      width: 1px;
      height: 1px;
      opacity: 0;
      pointer-events: none;
    }

    .ins-platform-picker__option:has(.ins-platform-picker__input:focus-visible) {
      outline: 2px solid var(--ins-series-1);
      outline-offset: 2px;
    }

    .ins-platform-picker__option-copy {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
    }

    .ins-platform-picker__option-identity {
      display: grid;
      gap: 0.125rem;
      min-width: 0;
    }

    .ins-platform-picker__option-name {
      font-size: var(--ins-text-small);
      font-weight: 600;
    }

    .ins-platform-picker__option-description {
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
    }

    .ins-platform-picker__option-count {
      font-size: var(--ins-text-small);
      font-weight: 650;
      color: var(--ins-ink);
    }

    @media (width < 48rem) {
      .ins-platform-picker {
        width: min(17rem, 42vw);
      }

      .ins-platform-picker__trigger-count {
        display: none;
      }
    }
  `,
})
export class PlatformPicker {
  private readonly store = inject(DashboardStore);
  private readonly host = inject(ElementRef<HTMLElement>);
  private readonly trigger = viewChild<ElementRef<HTMLButtonElement>>('trigger');

  protected readonly isOpen = signal(false);
  protected readonly exact = whole;
  protected readonly resourceCount = (count: number): string => pluralize(count, 'resource');

  protected readonly options = computed<readonly PlatformOption[]>(() => {
    const counts = this.store.platformCounts();
    const countByPlatform = new Map(counts.map((entry) => [entry.platform, entry.count]));
    const total = counts.reduce((sum, entry) => sum + entry.count, 0);
    const scopes = platformScopes(counts.map((entry) => entry.platform)).map((scope) => ({
      ...scope,
      count: scope.platforms.reduce(
        (sum, platform) => sum + (countByPlatform.get(platform) ?? 0),
        0,
      ),
    }));
    const largest = Math.max(...scopes.map((scope) => scope.count), 1);

    return [
      {
        value: 'all' as const,
        label: 'Overview',
        description: null,
        count: total,
        share: 100,
        color: 'var(--ins-ink-muted)',
      },
      ...scopes.map((scope) => ({
        value: scope.value,
        label: scope.label,
        description: scope.description,
        count: scope.count,
        share: (scope.count / largest) * 100,
        color: scopeColor(scope.platforms),
      })),
    ];
  });

  protected readonly selected = computed(
    () =>
      this.options().find((option) => option.value === this.store.platformFilter()) ??
      this.options()[0],
  );

  protected toggle(): void {
    this.isOpen.update((open) => !open);
  }

  protected isSelected(option: PlatformOption): boolean {
    return this.store.platformFilter() === option.value;
  }

  protected select(option: PlatformOption): void {
    this.store.setPlatformFilter(option.value);
    this.isOpen.set(false);
    this.trigger()?.nativeElement.focus();
  }

  protected closeAndRestoreFocus(): void {
    if (!this.isOpen()) {
      return;
    }

    this.isOpen.set(false);
    this.trigger()?.nativeElement.focus();
  }

  protected onDocumentPointerDown(event: PointerEvent): void {
    if (this.isOpen() && !this.host.nativeElement.contains(event.target as Node)) {
      this.isOpen.set(false);
    }
  }
}

/** A group keeps the member registries' official colours in one proportional identity line. */
function scopeColor(platforms: readonly Parameters<typeof platformColor>[0][]): string {
  if (platforms.length === 0) {
    return 'var(--ins-ink-muted)';
  }
  if (platforms.length === 1) {
    return platformColor(platforms[0]);
  }

  const stops = platforms.flatMap((platform, index) => {
    const start = (index / platforms.length) * 100;
    const end = ((index + 1) / platforms.length) * 100;
    const color = platformColor(platform);
    return [`${color} ${start}%`, `${color} ${end}%`];
  });
  return `linear-gradient(90deg, ${stops.join(', ')})`;
}
