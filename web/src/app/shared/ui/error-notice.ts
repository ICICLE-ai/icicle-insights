import { Component, computed, input, output } from '@angular/core';

import { toApiError } from '../../core/api/api-error';

/**
 * Explains a failed request and offers a retry.
 *
 * The request ID is shown whenever the server sent one. A 401 from this API deliberately never
 * says *why* a credential failed — that reason exists only in the server log — so the ID is the
 * only thing that connects what the user saw to what an operator can look up. Hiding it because
 * it looks technical would strand every support conversation about a refused sign-in.
 *
 * `role="alert"` so the failure is announced when it replaces a loading state, rather than
 * silently swapping in for a sighted-only audience.
 */
@Component({
  selector: 'app-error-notice',
  template: `
    <div class="ins-error" role="alert">
      <p class="ins-error__message">
        <span class="ins-error__icon" aria-hidden="true">⚠</span>
        {{ failure().message }}
      </p>

      @if (failure().detail; as detail) {
        <p class="ins-error__detail">{{ detail }}</p>
      }

      @if (failure().requestID; as requestID) {
        <p class="ins-error__meta">
          Request ID <code>{{ requestID }}</code> — quote this when reporting the problem.
        </p>
      }

      <button type="button" class="ins-error__retry" (click)="retry.emit()">Try again</button>
    </div>
  `,
  styles: `
    .ins-error {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 0.625rem;
      padding: 1.25rem;
      background: var(--ins-surface);
      /* Colour is reinforced by the icon and the wording, never carrying the meaning alone. */
      border: 1px solid var(--ins-critical);
      border-radius: 0.75rem;
    }

    .ins-error__message {
      display: flex;
      gap: 0.5rem;
      margin: 0;
      font-weight: 500;
      color: var(--ins-ink);
    }

    .ins-error__icon {
      color: var(--ins-critical);
    }

    .ins-error__detail,
    .ins-error__meta {
      margin: 0;
      font-size: 0.8125rem;
      color: var(--ins-ink-secondary);
    }

    .ins-error__meta code {
      font-family: ui-monospace, monospace;
      font-size: 0.75rem;
      color: var(--ins-ink);
    }

    .ins-error__retry {
      min-height: 2.75rem;
      padding: 0.5rem 1rem;
      font: inherit;
      font-size: 0.875rem;
      color: var(--ins-ink);
      background: transparent;
      border: 1px solid var(--ins-border);
      border-radius: 0.5rem;
      cursor: pointer;
    }
  `,
})
export class ErrorNotice {
  /** The thrown value, normalised here so callers can pass whatever the resource surfaced. */
  readonly error = input.required<unknown>();
  readonly retry = output<void>();

  protected readonly failure = computed(() => toApiError(this.error()));
}
