import { HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { describe, expect, it } from 'vitest';

import { toApiError } from './api-error';

const failure = (init: {
  status: number;
  headers?: Record<string, string>;
  error?: unknown;
}) =>
  new HttpErrorResponse({
    status: init.status,
    headers: new HttpHeaders(init.headers ?? {}),
    error: init.error,
  });

describe('toApiError', () => {
  it('separates "not signed in" from "signed in but not permitted"', () => {
    // The two call for different actions, so they must never share wording: 401 sends someone to
    // authenticate, 403 tells them authenticating again will not help.
    const unauthorized = toApiError(failure({ status: 401 }));
    const forbidden = toApiError(failure({ status: 403 }));

    expect(unauthorized.kind).toBe('unauthorized');
    expect(forbidden.kind).toBe('forbidden');
    expect(unauthorized.message).not.toBe(forbidden.message);
    expect(forbidden.message).toContain('administrator');
  });

  it('carries the request ID through, since a 401 never says why', () => {
    const error = toApiError(
      failure({ status: 401, headers: { 'X-Request-ID': 'abc-123' } }),
    );

    expect(error.requestID).toBe('abc-123');
  });

  it('names an HTML body served with 200 as its own failure', () => {
    // The SPA fallback swallowing an API call. The status is 200 and only the body gives it
    // away, which is exactly why checking the status code alone cannot catch it.
    const error = toApiError(
      failure({ status: 200, headers: { 'Content-Type': 'text/html' }, error: '<!doctype html>' }),
    );

    expect(error.kind).toBe('notJson');
    expect(error.message).toContain('web page instead of data');
    expect(error.detail).toContain('ng serve');
  });

  it('does not mistake a genuine JSON 200 for the fallback', () => {
    const error = toApiError(
      failure({ status: 200, headers: { 'Content-Type': 'application/json' } }),
    );

    expect(error.kind).not.toBe('notJson');
  });

  it('surfaces the server reason when it sent one', () => {
    const error = toApiError(failure({ status: 409, error: { reason: 'Vault name taken.' } }));

    expect(error.kind).toBe('conflict');
    expect(error.detail).toBe('Vault name taken.');
  });

  it('drops a body of an unexpected shape rather than stringifying it', () => {
    // An HTML error page is as likely here as a useful sentence, and rendering markup into the
    // error UI is worse than saying nothing.
    expect(toApiError(failure({ status: 500, error: '<html>oops</html>' })).detail).toBeNull();
  });

  it('treats a status of 0 as never having reached the server', () => {
    expect(toApiError(failure({ status: 0 })).kind).toBe('offline');
  });
});
