import { Component, computed, inject } from '@angular/core';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';
import { ConfirmDialogModule } from '@openng/optimus-ui/confirmdialog';
import { ToastModule } from '@openng/optimus-ui/toast';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

import { AppNav } from '../../shared/ui/app-nav';
import { SessionStore } from '../../core/auth/session-store';

const expiryFormatter = new Intl.DateTimeFormat('en-US', {
  hour: 'numeric',
  minute: '2-digit',
  timeZoneName: 'short',
});

const confirmDialogPassThrough = {
  host: { 'aria-label': 'Confirm action' },
  pcCloseButton: { root: { 'aria-label': 'Close confirmation' } },
};

/** Stable admin chrome; feature pages are lazy children inside the content region. */
@Component({
  selector: 'app-admin-shell',
  imports: [AppNav, ConfirmDialogModule, RouterLink, RouterLinkActive, RouterOutlet, ToastModule],
  template: `
    <header class="ins-admin-masthead">
      <div class="ins-admin-masthead__copy">
        <p class="ins-eyebrow">Administration</p>
        <h1>Operations console</h1>
      </div>
      <app-nav />
    </header>

    <nav class="ins-admin-tabs" aria-label="Administration sections">
      <a
        routerLink="/admin"
        routerLinkActive="is-active"
        [routerLinkActiveOptions]="{ exact: true }"
        ariaCurrentWhenActive="page"
      >
        Operations
      </a>
      <a routerLink="/admin/vaults" routerLinkActive="is-active" ariaCurrentWhenActive="page">
        Vaults
      </a>
      <a
        routerLink="/admin/service-tokens"
        routerLinkActive="is-active"
        ariaCurrentWhenActive="page"
      >
        Service tokens
      </a>
      <a
        routerLink="/admin/administrators"
        routerLinkActive="is-active"
        ariaCurrentWhenActive="page"
      >
        Administrators
      </a>
      <a routerLink="/admin/catalog" routerLinkActive="is-active" ariaCurrentWhenActive="page">
        Catalog
      </a>
    </nav>

    @if (session.isExpired() || session.expiresSoon()) {
      <p class="ins-admin-session-warning" role="status">
        <span aria-hidden="true">!</span>
        @if (session.isExpired()) {
          Your Tapis token has expired. Save no further changes; reopen this dashboard from TapisUI
          to refresh the session.
        } @else {
          Your Tapis session expires at {{ expiryLabel() }}. Finish or save credential work before
          refreshing it through TapisUI.
        }
      </p>
    }

    <div class="ins-admin-content">
      <router-outlet />
    </div>

    <p-toast position="bottom-right" />
    <p-confirmdialog
      header="Confirm action"
      closeAriaLabel="Close confirmation"
      [closable]="true"
      [pt]="confirmDialogPassThrough"
    />
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      flex-direction: column;
      min-height: 100%;
    }

    .ins-admin-masthead {
      display: grid;
      grid-template-columns: minmax(0, max-content) minmax(5.25rem, 1fr);
      align-items: stretch;
      gap: 1rem;
      min-height: var(--ins-masthead-height);
      margin-bottom: 0.875rem;
    }

    .ins-admin-masthead__copy {
      display: flex;
      flex-direction: column;
      justify-content: center;
      min-width: 12rem;
    }

    .ins-admin-masthead p,
    .ins-admin-masthead h1 {
      margin: 0;
    }

    .ins-admin-masthead h1 {
      font-size: var(--ins-text-title);
      line-height: 1.2;
    }

    .ins-admin-content {
      display: flex;
      flex: 1;
      min-height: 0;
    }

    .ins-admin-tabs {
      display: grid;
      grid-template-columns: repeat(5, minmax(0, 1fr));
      gap: 0.25rem;
      margin-bottom: 0.5rem;
      padding: 0.25rem;
      overflow-x: auto;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
    }

    .ins-admin-tabs a {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 8.5rem;
      min-height: var(--ins-section-nav-height);
      padding: 0.375rem 0.75rem;
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-small);
      font-weight: 650;
      text-decoration: none;
      white-space: nowrap;
      border: 1px solid transparent;
      border-radius: var(--ins-radius-sm);
    }

    .ins-admin-tabs a:hover {
      color: var(--ins-ink);
      background: var(--ins-raised);
    }

    .ins-admin-tabs a.is-active {
      color: var(--ins-ink);
      background: var(--ins-raised);
      border-color: var(--ins-border-strong);
      box-shadow: inset 0 -3px 0 var(--ins-series-1);
    }

    .ins-admin-session-warning {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin: 0 0 0.75rem;
      padding: 0.625rem 0.75rem;
      color: var(--ins-ink-secondary);
      background: var(--ins-surface);
      border: 1px solid var(--ins-warning);
      border-radius: var(--ins-radius-sm);
      font-size: var(--ins-text-small);
    }

    .ins-admin-session-warning > span {
      display: grid;
      place-items: center;
      width: 1.25rem;
      height: 1.25rem;
      flex: none;
      color: var(--ins-ink);
      border: 1px solid var(--ins-warning);
      border-radius: 50%;
      font-weight: 700;
    }

    @media (width < 48rem) {
      .ins-admin-masthead {
        gap: 0.75rem;
      }

      .ins-admin-masthead__copy {
        min-width: 0;
      }

      .ins-admin-tabs {
        grid-template-columns: none;
        grid-auto-columns: max-content;
        grid-auto-flow: column;
      }
    }
  `,
})
export class AdminShell {
  protected readonly session = inject(SessionStore);
  protected readonly confirmDialogPassThrough = confirmDialogPassThrough;
  protected readonly expiryLabel = computed(() => {
    const expiry = this.session.expiresAt();
    return expiry ? expiryFormatter.format(expiry) : '';
  });
}
