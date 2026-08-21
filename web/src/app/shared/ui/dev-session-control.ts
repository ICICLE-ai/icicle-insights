import { Component, ElementRef, computed, inject, signal, viewChild } from '@angular/core';
import { DialogModule } from '@openng/optimus-ui/dialog';
import { InputTextModule } from '@openng/optimus-ui/inputtext';

import { SessionStore } from '../../core/auth/session-store';
import { TokenStore } from '../../core/auth/token-store';

/** Local-only, memory-only staging authentication control. */
@Component({
  selector: 'app-dev-session-control',
  imports: [DialogModule, InputTextModule],
  template: `
    <button
      #trigger
      type="button"
      class="ins-session-trigger"
      aria-haspopup="dialog"
      aria-controls="dev-session-dialog"
      [attr.aria-expanded]="isDialogOpen()"
      (click)="openDialog()"
    >
      <span
        class="ins-session-trigger__status"
        [class.is-active]="tokens.hasToken()"
        aria-hidden="true"
      ></span>
      <span>Test session</span>
    </button>

    <p-dialog
      id="dev-session-dialog"
      header="Local staging session"
      closeAriaLabel="Close local staging session"
      [modal]="true"
      [draggable]="false"
      [resizable]="false"
      [dismissableMask]="true"
      [blockScroll]="true"
      [style]="dialogStyle"
      [breakpoints]="dialogBreakpoints"
      [visible]="isDialogOpen()"
      (visibleChange)="setDialogVisibility($event)"
      (onHide)="restoreFocus()"
    >
      <p class="ins-dev-session__hint">
        Development only. The token stays in memory and is cleared when the page reloads.
      </p>

      @if (tokens.hasToken()) {
        <div class="ins-dev-session__active">
          <span class="ins-dev-session__status" role="status">{{ statusLabel() }}</span>
          <button type="button" class="ins-dev-session__button" (click)="clear()">
            Clear test session
          </button>
        </div>
      } @else {
        <form class="ins-dev-session__form" (submit)="signIn($event)">
          <label for="dev-tapis-token">Staging Tapis token</label>
          <input
            id="dev-tapis-token"
            pInputText
            type="password"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            placeholder="Paste staging Tapis token"
            [value]="draft()"
            (input)="updateDraft($event)"
          />
          <button type="submit" class="ins-dev-session__button" [disabled]="!canSubmit()">
            Use test token
          </button>
        </form>
      }
    </p-dialog>
  `,
  styles: `
    .ins-session-trigger {
      display: inline-flex;
      align-items: center;
      gap: 0.4375rem;
      min-height: 2.25rem;
      padding: 0.375rem 0.625rem;
      font: inherit;
      font-size: var(--ins-text-small);
      font-weight: 600;
      color: var(--ins-ink-secondary);
      background: transparent;
      border: 1px solid transparent;
      border-radius: var(--ins-radius-sm);
      cursor: pointer;
      white-space: nowrap;
    }

    .ins-session-trigger:hover,
    .ins-session-trigger[aria-expanded='true'] {
      color: var(--ins-ink);
      background: var(--ins-raised);
      border-color: var(--ins-border);
    }

    .ins-session-trigger__status {
      width: 0.5rem;
      height: 0.5rem;
      flex: none;
      background: var(--ins-ink-muted);
      border-radius: 50%;
    }

    .ins-session-trigger__status.is-active {
      background: var(--ins-good);
    }

    .ins-dev-session__hint {
      margin: 0 0 1rem;
      color: var(--ins-ink-secondary);
      font-size: var(--ins-text-small);
      line-height: 1.55;
    }

    .ins-dev-session__form {
      display: grid;
      gap: 0.625rem;
    }

    .ins-dev-session__form label {
      font-size: var(--ins-text-small);
      font-weight: 650;
      color: var(--ins-ink);
    }

    .ins-dev-session__form input {
      width: 100%;
      min-height: 2.5rem;
      font: var(--ins-text-small) var(--ins-font-mono);
    }

    .ins-dev-session__active {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      padding: 0.75rem;
      background: var(--ins-raised);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
    }

    .ins-dev-session__status {
      font-size: var(--ins-text-small);
      color: var(--ins-ink-secondary);
    }

    .ins-dev-session__button {
      justify-self: end;
      min-height: 2.375rem;
      padding: 0.4375rem 0.875rem;
      font: inherit;
      font-size: var(--ins-text-small);
      font-weight: 650;
      color: #ffffff;
      background: var(--ins-series-1);
      border: 1px solid var(--ins-series-1);
      border-radius: var(--ins-radius-sm);
      cursor: pointer;
      white-space: nowrap;
    }

    .ins-dev-session__button:hover:not(:disabled) {
      filter: brightness(0.94);
    }

    .ins-dev-session__button:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
  `,
})
export class DevSessionControl {
  protected readonly tokens = inject(TokenStore);
  private readonly session = inject(SessionStore);

  protected readonly draft = signal('');
  protected readonly canSubmit = computed(() => this.draft().trim().length > 0);
  protected readonly isDialogOpen = signal(false);
  protected readonly dialogStyle = { width: '28rem', maxWidth: 'calc(100vw - 2rem)' };
  protected readonly dialogBreakpoints = { '575px': 'calc(100vw - 2rem)' };

  private readonly trigger = viewChild<ElementRef<HTMLButtonElement>>('trigger');

  protected readonly statusLabel = computed(() => {
    switch (this.session.status()) {
      case 'admin':
        return `Admin confirmed${this.session.username() ? ` · ${this.session.username()}` : ''}`;
      case 'authenticated':
        return `Signed in${this.session.username() ? ` · ${this.session.username()}` : ''}`;
      case 'unknown':
        return 'Checking access…';
      default:
        return 'Token rejected or expired';
    }
  });

  protected openDialog(): void {
    this.isDialogOpen.set(true);
  }

  protected setDialogVisibility(visible: boolean): void {
    this.isDialogOpen.set(visible);
  }

  protected restoreFocus(): void {
    this.trigger()?.nativeElement.focus();
  }

  protected updateDraft(event: Event): void {
    this.draft.set((event.target as HTMLInputElement).value);
  }

  protected signIn(event: SubmitEvent): void {
    event.preventDefault();
    if (!this.canSubmit()) {
      return;
    }

    this.tokens.setManualToken(this.draft());
    this.draft.set('');
  }

  protected clear(): void {
    this.tokens.clear();
    this.draft.set('');
  }
}
