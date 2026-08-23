import { HttpErrorResponse } from '@angular/common/http';

/** How a failed request should be explained to the person looking at the screen. */
export type ApiFailureKind =
  | 'offline'
  | 'unauthorized'
  | 'forbidden'
  | 'notFound'
  | 'conflict'
  | 'rateLimited'
  | 'upstream'
  | 'unavailable'
  | 'server'
  | 'notJson'
  | 'unknown';

/**
 * A request failure reduced to what the UI needs.
 *
 * Carries `requestID` because every response from this API includes `X-Request-ID`, and quoting
 * it is what lets a bug report be traced to a specific log line. A 401 deliberately never says
 * *why* the credential failed — that reason exists only in the server log, correlated by this
 * ID — so without it a support conversation about a refused login has nothing to go on.
 */
export interface ApiError {
  readonly kind: ApiFailureKind;
  /** HTTP status, or 0 when the request never reached the server. */
  readonly status: number;
  /** Sentence suitable for display. Never contains credentials. */
  readonly message: string;
  readonly requestID: string | null;
  /** Server-supplied reason, when it sent one worth showing. */
  readonly detail: string | null;
}

/** Maps a status onto the failure kinds documented in `docs/frontend.md`. */
function kindFor(status: number): ApiFailureKind {
  switch (status) {
    case 0:
      return 'offline';
    case 401:
      return 'unauthorized';
    case 403:
      return 'forbidden';
    case 404:
      return 'notFound';
    case 409:
      return 'conflict';
    case 429:
      return 'rateLimited';
    case 502:
      return 'upstream';
    case 503:
      return 'unavailable';
    default:
      return status >= 500 ? 'server' : 'unknown';
  }
}

/**
 * Wording for each failure.
 *
 * 401 and 403 are given genuinely different sentences. They mean different things — nobody
 * authenticated, versus authenticated but not permitted — and collapsing them into one
 * "access denied" sends a signed-in non-admin hunting for a login button that would not help.
 */
function messageFor(kind: ApiFailureKind): string {
  switch (kind) {
    case 'offline':
      return 'Could not reach the Insights API. Check your connection and try again.';
    case 'unauthorized':
      return 'You are not signed in, or your Tapis session has expired.';
    case 'forbidden':
      return 'You are signed in, but this action needs administrator access.';
    case 'notFound':
      return 'That record no longer exists.';
    case 'conflict':
      return 'That conflicts with something that already exists.';
    case 'rateLimited':
      return 'Too many requests. Wait a moment and try again.';
    case 'upstream':
      return 'An upstream service failed. This is not a problem with your request.';
    case 'unavailable':
      return 'The service is not ready to handle that yet.';
    case 'server':
      return 'The server failed to handle that request.';
    case 'notJson':
      return 'The API returned a web page instead of data, so nothing reached this request.';
    default:
      return 'Something went wrong handling that request.';
  }
}

/**
 * Whether a "successful" response was actually HTML the API never sent.
 *
 * This is the single-page-application fallback swallowing an API call: a catchall serving
 * `index.html` answers *every* path with 200, so a misrouted API request looks identical to a
 * working one until something tries to read the body. Locally it means `ng serve` is running
 * without its proxy — the dev server reads `proxyConfig` only at startup, so editing
 * `angular.json` while it runs leaves the proxy off. In a deployment it would mean the SPA
 * catchall is winning against `/api`.
 *
 * Worth naming rather than reporting as a parse failure, because "Unexpected token '<'" says
 * nothing about which request failed or why, and this failure is otherwise invisible: the status
 * is 200 and only the body gives it away. Checking the status code alone cannot detect it.
 */
function isHtmlInsteadOfJson(error: HttpErrorResponse): boolean {
  if (error.status !== 200) {
    return false;
  }

  const contentType = error.headers.get('Content-Type') ?? '';
  return contentType.includes('text/html');
}

/**
 * Extracts the server's own explanation, when it sent one fit to display.
 *
 * Vapor's `AbortError` responses carry `{ "reason": "..." }`, and errors crossing this API's
 * boundary are required to exclude credentials from that reason. Anything of another shape is
 * dropped rather than stringified, because an unexpected body is as likely to be an HTML error
 * page as a useful sentence.
 */
function detailFrom(error: HttpErrorResponse): string | null {
  const body: unknown = error.error;
  if (typeof body !== 'object' || body === null) {
    return null;
  }

  const reason = (body as { reason?: unknown }).reason;
  return typeof reason === 'string' && reason.trim() ? reason.trim() : null;
}

/** Normalises Angular's error response into the shape the UI renders. */
export function toApiError(error: unknown): ApiError {
  if (!(error instanceof HttpErrorResponse)) {
    return {
      kind: 'unknown',
      status: 0,
      message: messageFor('unknown'),
      requestID: null,
      detail: null,
    };
  }

  const kind = isHtmlInsteadOfJson(error) ? 'notJson' : kindFor(error.status);
  return {
    kind,
    status: error.status,
    message: messageFor(kind),
    requestID: error.headers.get('X-Request-ID'),
    detail:
      kind === 'notJson'
        ? 'Restart `ng serve` so it picks up proxy.conf.json — it reads that only at startup.'
        : detailFrom(error),
  };
}
