import { Component, ElementRef, inject, isDevMode, signal, viewChild } from '@angular/core';

import { DevSessionControl } from './dev-session-control';
import { ExperimentPicker } from './experiment-picker';

/**
 * Keeps the temporary A/B controls available without spending permanent dashboard space.
 *
 * The production build removes the entire control through `isDevMode()`. In development, one
 * fixed disclosure opens upward from the bottom-right corner. New design comparisons can be
 * added here without spending permanent dashboard space or leaking into production builds.
 */
@Component({
  selector: 'app-dev-tools',
  imports: [DevSessionControl, ExperimentPicker],
  host: {
    '(keydown.escape)': 'closeAndRestoreFocus()',
    '(document:pointerdown)': 'onDocumentPointerDown($event)',
  },
  template: `
    @if (devMode) {
      <div class="ins-dev-tools">
        <div
          id="development-tools-options"
          class="ins-dev-tools__panel"
          role="group"
          aria-label="A/B test controls"
          [hidden]="!isOpen()"
        >
          <app-experiment-picker />
          <app-dev-session-control />
        </div>

        <button
          #trigger
          type="button"
          class="ins-dev-tools__trigger"
          aria-controls="development-tools-options"
          [attr.aria-expanded]="isOpen()"
          (click)="toggle()"
        >
          <span class="ins-dev-tools__icon" aria-hidden="true">A/B</span>
          <span>Test lab</span>
        </button>
      </div>
    }
  `,
  styles: `
    :host {
      position: fixed;
      right: 1.25rem;
      bottom: 1.25rem;
      z-index: 40;
      pointer-events: none;
    }

    .ins-dev-tools {
      position: relative;
      display: flex;
      flex-direction: column;
      align-items: flex-end;
      gap: 0.5rem;
      pointer-events: auto;
    }

    .ins-dev-tools__panel {
      display: flex;
      align-items: center;
      gap: 0.25rem;
      padding: 0.375rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border-strong);
      border-radius: var(--ins-radius);
      box-shadow: 0 12px 32px rgb(11 15 20 / 16%);
    }

    .ins-dev-tools__panel[hidden] {
      display: none;
    }

    .ins-dev-tools__trigger {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 0.4375rem;
      min-height: 2.625rem;
      padding: 0.5rem 0.875rem;
      font: inherit;
      font-size: var(--ins-text-small);
      font-weight: 650;
      /* Surface, not a literal white: the fill is --ins-ink, which inverts between themes, so a
       * hardcoded white left this button white-on-white and unreadable in dark mode. Pairing the
       * two tokens keeps the contrast inverted along with them, hover included. */
      color: var(--ins-surface);
      background: var(--ins-ink);
      border: 1px solid var(--ins-ink);
      border-radius: 999px;
      box-shadow: 0 8px 24px rgb(11 15 20 / 20%);
      cursor: pointer;
    }

    .ins-dev-tools__trigger:hover,
    .ins-dev-tools__trigger[aria-expanded='true'] {
      background: var(--ins-series-1);
      border-color: var(--ins-series-1);
    }

    .ins-dev-tools__icon {
      font-family: var(--ins-font-mono);
      font-size: var(--ins-text-micro);
      font-weight: 700;
      line-height: 1;
    }

    @media (width < 36rem) {
      :host {
        right: 0.75rem;
        bottom: 0.75rem;
      }
    }
  `,
})
export class DevTools {
  protected readonly devMode = isDevMode();
  protected readonly isOpen = signal(false);

  private readonly host = inject(ElementRef<HTMLElement>);
  private readonly trigger = viewChild<ElementRef<HTMLButtonElement>>('trigger');

  protected toggle(): void {
    this.isOpen.update((open) => !open);
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
