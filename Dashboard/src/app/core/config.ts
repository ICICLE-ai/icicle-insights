import { InjectionToken } from '@angular/core';

/** Deployment-specific values the application must not hard-code. */
export interface InsightsConfig {
  /**
   * Base path for every API call.
   *
   * The reads were top-level before the API was namespaced, which left the old dashboard
   * fetching 404s and rendering an empty page while still returning 200 itself.
   */
  readonly apiBase: string;

  /**
   * Cookie the Tapis Pods auth callback writes the token into.
   *
   * Readable from script only if Pods omits `HttpOnly` and the pod shares a registrable domain
   * with whoever set it. Both hold for a pod under `*.tapis.io`; neither is guaranteed, which
   * is why the cookie is one leg of a chain rather than the only path.
   */
  readonly tokenCookieName: string;

  /**
   * Origins permitted to hand this application a token over `postMessage`.
   *
   * **Empty by default, and that is deliberate.** An unconfigured allowlist accepts nothing;
   * the alternative — treating empty as "trust anyone" — would let any page that frames this
   * one inject a token of its choosing. Populate it with the exact TapisUI origins at deploy
   * time, scheme and host, no trailing slash.
   */
  readonly trustedParentOrigins: readonly string[];
}

export const INSIGHTS_CONFIG = new InjectionToken<InsightsConfig>('INSIGHTS_CONFIG');

/** Defaults for local development against `ng serve` with the `/api` proxy. */
export const defaultInsightsConfig: InsightsConfig = {
  apiBase: '/api',
  tokenCookieName: 'X-Tapis-Token',
  trustedParentOrigins: [],
};
