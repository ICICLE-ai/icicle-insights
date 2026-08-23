import { HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';

import { INSIGHTS_CONFIG } from '../config';
import { TokenStore } from './token-store';

/**
 * Generates a correlation ID the server will echo back.
 *
 * The server constrains these to `[A-Za-z0-9_-]` at 64 characters and silently replaces anything
 * else, so a UUID — hex and hyphens, 36 characters — is always accepted verbatim. The fallback
 * matters because `crypto.randomUUID` is unavailable on insecure origins, which includes plain
 * `http://` development hosts other than localhost.
 */
function newRequestID(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }

  return `ins-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
}

/**
 * Attaches the bearer credential and a correlation ID to Insights API requests.
 *
 * The token is attached **only** to requests aimed at the configured API base. Angular's
 * `HttpClient` is used for other things over time — a static asset, a health probe, some future
 * third-party call — and a blanket header would hand this user's Tapis credential to whoever
 * that request happened to target.
 *
 * Requests are never blocked for lacking a token. Reads are public, so an anonymous request is
 * ordinary traffic rather than an error, and the server's `Require` middleware is what decides
 * whether a given route needed one.
 */
export const authInterceptor: HttpInterceptorFn = (request, next) => {
  const config = inject(INSIGHTS_CONFIG);
  const tokens = inject(TokenStore);

  if (!request.url.startsWith(config.apiBase)) {
    return next(request);
  }

  const headers: Record<string, string> = { 'X-Request-ID': newRequestID() };

  const token = tokens.token();
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  return next(request.clone({ setHeaders: headers }));
};
