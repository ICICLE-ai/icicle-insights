import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';

/** Catalog-specific navigation keeps each record type in a focused, one-screen editor. */
@Component({
  selector: 'app-catalog-shell',
  imports: [RouterOutlet],
  template: `
    <div class="ins-catalog-shell">
      <div class="ins-catalog-content">
        <router-outlet />
      </div>
    </div>
  `,
  styles: `
    :host,
    .ins-catalog-shell,
    .ins-catalog-content {
      display: flex;
      flex: 1;
      flex-direction: column;
      min-width: 0;
      min-height: 0;
    }
  `,
})
export class CatalogShell {}
