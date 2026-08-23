import { Component } from '@angular/core';
import { RouterLink } from '@angular/router';

@Component({
  selector: 'app-not-found',
  imports: [RouterLink],
  template: `
    <section class="ins-not-found">
      <h2>That page does not exist</h2>
      <p>The link may be out of date, or the record it pointed at may have been removed.</p>
      <a routerLink="/">Back to the dashboard</a>
    </section>
  `,
  styles: `
    .ins-not-found {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 0.75rem;
      padding: 3rem 0;
    }

    h2 {
      margin: 0;
      font-size: 1.25rem;
      color: var(--ins-ink);
    }

    p {
      margin: 0;
      color: var(--ins-ink-secondary);
    }

    a {
      color: var(--ins-series-1);
    }
  `,
})
export class NotFound {}
