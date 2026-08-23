import { Component, computed, inject } from '@angular/core';
import { RouterLink } from '@angular/router';

import { SessionStore } from '../../core/auth/session-store';
import { AppNav } from '../../shared/ui/app-nav';

/** A useful destination for direct admin URLs that do not pass the server-backed guard. */
@Component({
  selector: 'app-admin-access',
  imports: [AppNav, RouterLink],
  template: `
    <header class="ins-access__masthead">
      <div>
        <p class="ins-eyebrow">Administration</p>
        <h1>Access check</h1>
      </div>
      <app-nav />
    </header>

    <section class="ins-access" aria-labelledby="access-title">
      <span class="ins-access__mark" aria-hidden="true">{{ message().mark }}</span>
      <div class="ins-access__copy">
        <p class="ins-eyebrow">{{ message().eyebrow }}</p>
        <h2 id="access-title">{{ message().title }}</h2>
        <p>{{ message().body }}</p>

        <div class="ins-access__actions">
          @if (session.isAdmin()) {
            <a class="ins-access__primary" routerLink="/admin">Open administration</a>
          }
          <a class="ins-access__secondary" routerLink="/">Return to overview</a>
        </div>
      </div>
    </section>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      flex-direction: column;
    }

    .ins-access__masthead {
      display: grid;
      grid-template-columns: minmax(0, max-content) minmax(5.25rem, 1fr);
      align-items: stretch;
      gap: 1rem;
      min-height: var(--ins-masthead-height);
      margin-bottom: 0.875rem;
    }

    .ins-access__masthead > div {
      display: flex;
      flex-direction: column;
      justify-content: center;
    }

    .ins-access__masthead p,
    .ins-access__masthead h1 {
      margin: 0;
    }

    .ins-access__masthead h1 {
      font-size: var(--ins-text-title);
      line-height: 1.2;
    }

    .ins-access {
      display: grid;
      grid-template-columns: 4rem minmax(0, 36rem);
      align-items: start;
      justify-content: center;
      gap: 1.25rem;
      margin-block: auto;
      padding: 3rem 1.5rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
    }

    .ins-access__mark {
      display: grid;
      place-items: center;
      width: 4rem;
      height: 4rem;
      color: var(--ins-series-1);
      background: var(--ins-raised);
      border: 1px solid var(--ins-border);
      border-radius: 50%;
      font-size: 1.5rem;
      font-weight: 700;
    }

    .ins-access__copy {
      display: grid;
      gap: 0.625rem;
    }

    .ins-access__copy p,
    .ins-access__copy h2 {
      margin: 0;
    }

    .ins-access__copy h2 {
      font-size: var(--ins-text-title);
      line-height: 1.25;
    }

    .ins-access__copy > p:not(.ins-eyebrow) {
      color: var(--ins-ink-secondary);
      line-height: 1.6;
    }

    .ins-access__actions {
      display: flex;
      flex-wrap: wrap;
      gap: 0.625rem;
      margin-top: 0.5rem;
    }

    .ins-access__primary,
    .ins-access__secondary {
      display: inline-flex;
      align-items: center;
      min-height: 2.75rem;
      padding: 0.5rem 1rem;
      font-weight: 650;
      text-decoration: none;
      border: 1px solid var(--ins-series-1);
      border-radius: var(--ins-radius-sm);
    }

    .ins-access__primary {
      color: #ffffff;
      background: var(--ins-series-1);
    }

    .ins-access__secondary {
      color: var(--ins-ink);
      background: transparent;
      border-color: var(--ins-border-strong);
    }

    @media (width < 36rem) {
      .ins-access {
        grid-template-columns: 1fr;
      }
    }
  `,
})
export class AdminAccess {
  protected readonly session = inject(SessionStore);

  protected readonly message = computed(() => {
    switch (this.session.status()) {
      case 'admin':
        return {
          mark: '✓',
          eyebrow: 'Access confirmed',
          title: 'Administration is ready',
          body: 'Your account has administrator access. Open the operations console to continue.',
        };
      case 'authenticated':
        return {
          mark: '—',
          eyebrow: 'Signed in',
          title: 'Administrator access is required',
          body: 'Your Tapis identity was verified, but it is not an Insights administrator. Ask an existing administrator to add your username.',
        };
      case 'anonymous':
        return {
          mark: '○',
          eyebrow: 'No active session',
          title: 'Sign in through TapisUI',
          body: 'Open this dashboard from your TapisUI session so it can provide a current token. Public analytics remain available without signing in.',
        };
      default:
        return {
          mark: '…',
          eyebrow: 'Checking access',
          title: 'Verifying your Tapis session',
          body: 'The dashboard is waiting for the server to confirm your access level.',
        };
    }
  });
}
