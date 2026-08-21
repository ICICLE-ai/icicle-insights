import { Component, computed, inject } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';

import { SessionStore } from '../../core/auth/session-store';
import { ThemePicker } from './theme-picker';

interface NavSection {
  readonly path: string;
  readonly label: string;
  readonly exact: boolean;
}

const ADMIN_SECTIONS: readonly NavSection[] = [
  { path: '/', label: 'Overview', exact: true },
  { path: '/admin', label: 'Administration', exact: false },
];

/**
 * Stable page-level controls at the right edge of each masthead.
 *
 * The product mark is only branding. Theme selection is always available, including on public
 * pages. Once the server confirms an administrator, the admin navigation appears beside those
 * controls without requiring a disclosure interaction or changing the masthead's vertical size.
 */
@Component({
  selector: 'app-nav',
  imports: [RouterLink, RouterLinkActive, ThemePicker],
  template: `
    <div class="ins-nav">
      @if (session.isAdmin()) {
        <div class="ins-nav__admin">
          <nav aria-label="Primary">
            <ul class="ins-nav__sections">
              @for (section of sections; track section.path) {
                <li>
                  <a
                    class="ins-nav__link"
                    [routerLink]="section.path"
                    routerLinkActive="is-active"
                    [routerLinkActiveOptions]="{ exact: section.exact }"
                    ariaCurrentWhenActive="page"
                  >
                    {{ section.label }}
                  </a>
                </li>
              }
            </ul>
          </nav>

          @if (identity(); as who) {
            <span class="ins-nav__identity">
              <span class="ins-nav__avatar" aria-hidden="true">{{ who.glyph }}</span>
              <span class="ins-nav__identity-text">
                <span class="ins-nav__role">{{ who.role }}</span>
                @if (who.name) {
                  <span class="ins-nav__name ins-mono">{{ who.name }}</span>
                }
              </span>
            </span>
          }
        </div>
      }

      <div class="ins-nav__theme" role="group" aria-label="Display settings">
        <app-theme-picker />
      </div>

      <span class="ins-nav__brand" aria-label="ICICLE Insights">
        <span class="ins-nav__logo" aria-hidden="true">◆</span>
        <span class="ins-nav__compact-title">ICICLE Insights</span>
      </span>
    </div>
  `,
  styles: `
    :host {
      display: block;
      flex: 1 1 0;
      min-width: 8.5rem;
    }

    .ins-nav {
      display: flex;
      align-items: stretch;
      justify-content: flex-end;
      gap: 0.5rem;
      width: 100%;
      height: var(--ins-masthead-height);
    }

    .ins-nav__admin,
    .ins-nav__theme,
    .ins-nav__brand {
      box-sizing: border-box;
      height: var(--ins-masthead-height);
      min-height: var(--ins-masthead-height);
      color: var(--ins-ink-secondary);
      background: var(--ins-surface);
      border: 1px solid var(--ins-border-strong);
      border-radius: var(--ins-radius);
    }

    .ins-nav__admin {
      display: flex;
      align-items: center;
      gap: 0.625rem;
      width: max-content;
      max-width: calc(100% - 8rem);
      min-width: 0;
      padding: 0.25rem 0.5rem;
    }

    .ins-nav__sections {
      display: flex;
      align-items: center;
      gap: 0.125rem;
      margin: 0;
      padding: 0;
      list-style: none;
    }

    .ins-nav__link {
      display: inline-flex;
      align-items: center;
      min-height: 2rem;
      padding: 0.25rem 0.625rem;
      font-size: var(--ins-text-small);
      color: var(--ins-ink-secondary);
      text-decoration: none;
      border-radius: 999px;
      white-space: nowrap;
    }

    .ins-nav__link:hover {
      color: var(--ins-ink);
      background: var(--ins-raised);
    }

    .ins-nav__link.is-active {
      color: var(--ins-ink);
      font-weight: 650;
      background: var(--ins-raised);
      box-shadow: inset 0 0 0 1px var(--ins-series-1);
    }

    .ins-nav__identity {
      display: inline-flex;
      align-items: center;
      gap: 0.5rem;
      min-width: 0;
      padding-left: 0.625rem;
      border-left: 1px solid var(--ins-border);
    }

    .ins-nav__avatar {
      display: grid;
      place-items: center;
      width: 1.625rem;
      height: 1.625rem;
      flex: none;
      font-size: 0.875rem;
      color: #ffffff;
      background: var(--ins-series-1);
      border-radius: 50%;
    }

    .ins-nav__identity-text {
      display: flex;
      flex-direction: column;
      min-width: 0;
      line-height: 1.15;
    }

    .ins-nav__role {
      font-size: var(--ins-text-micro);
      font-weight: 600;
      color: var(--ins-ink-muted);
      text-transform: uppercase;
      letter-spacing: 0.06em;
    }

    .ins-nav__name {
      overflow: hidden;
      max-width: 9rem;
      font-size: var(--ins-text-small);
      color: var(--ins-ink);
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .ins-nav__theme {
      display: grid;
      place-items: center;
      width: 2.75rem;
      flex: none;
    }

    .ins-nav__brand {
      display: inline-flex;
      flex: none;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.125rem;
      min-width: 5.25rem;
      padding: 0.25rem 0.5rem;
    }

    .ins-nav__logo {
      color: var(--ins-series-1);
      font-size: 1rem;
      line-height: 1;
    }

    .ins-nav__compact-title {
      font-size: var(--ins-text-micro);
      font-weight: 650;
      line-height: 1.1;
      color: var(--ins-ink);
      white-space: nowrap;
    }

    @media (width < 48rem) {
      .ins-nav__identity {
        display: none;
      }

      .ins-nav__admin {
        max-width: calc(100% - 7.5rem);
      }
    }
  `,
})
export class AppNav {
  protected readonly session = inject(SessionStore);
  protected readonly sections = ADMIN_SECTIONS;

  protected readonly identity = computed(() => ({
    role: 'Admin',
    glyph: '★',
    name: this.session.username(),
  }));
}
