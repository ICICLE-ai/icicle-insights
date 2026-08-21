import { Component } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';

/** Shared record-type navigation, placed inside each catalog page's action header. */
@Component({
  selector: 'app-catalog-tabs',
  imports: [RouterLink, RouterLinkActive],
  template: `
    <nav class="ins-catalog-tabs" aria-label="Catalog record types">
      <a
        routerLink="/admin/catalog"
        routerLinkActive="is-active"
        [routerLinkActiveOptions]="{ exact: true }"
        ariaCurrentWhenActive="page"
      >
        Accounts
      </a>
      <a
        routerLink="/admin/catalog/resources"
        routerLinkActive="is-active"
        ariaCurrentWhenActive="page"
      >
        Resources
      </a>
      <a
        routerLink="/admin/catalog/releases"
        routerLinkActive="is-active"
        ariaCurrentWhenActive="page"
      >
        Releases
      </a>
      <a
        routerLink="/admin/catalog/metrics"
        routerLinkActive="is-active"
        ariaCurrentWhenActive="page"
      >
        Metrics
      </a>
    </nav>
  `,
  styles: `
    :host {
      display: block;
      min-width: 0;
    }

    .ins-catalog-tabs {
      display: flex;
      gap: 0.25rem;
      padding: 0.25rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: 999px;
    }

    .ins-catalog-tabs a {
      display: inline-flex;
      align-items: center;
      min-height: 2.25rem;
      padding: 0.375rem 0.75rem;
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-small);
      font-weight: 650;
      text-decoration: none;
      white-space: nowrap;
      border-radius: 999px;
    }

    .ins-catalog-tabs a:hover,
    .ins-catalog-tabs a.is-active {
      color: var(--ins-ink);
      background: var(--ins-raised);
    }

    .ins-catalog-tabs a.is-active {
      box-shadow: inset 0 0 0 1px var(--ins-series-1);
    }

    @media (width < 36rem) {
      .ins-catalog-tabs {
        width: 100%;
        overflow-x: auto;
        border-radius: var(--ins-radius);
      }
    }
  `,
})
export class CatalogTabs {}
