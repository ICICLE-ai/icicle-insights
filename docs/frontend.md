# Frontend contract

What a browser client can rely on. Written ahead of the Angular application, so treat the
serving-side sections as the plan and the API sections as current behaviour.

## Shape

Vapor serves everything: the API under `/api`, and the built frontend as static files from
`Public/`. One pod, no nginx, **no SSR** — server-side rendering would put Node in the runtime
image or add a second pod, and this is a dashboard rather than a page needing SEO.

No CDN. A single-region research dashboard behind a Kubernetes ingress does not have the traffic
profile to justify one, and it would add a cache-invalidation failure mode. Hashed bundles with
immutable cache headers plus ingress compression capture nearly all of the benefit.

## Authentication

**Send the token as `Authorization: Bearer <tapis-jwt>`.** Nothing else is read.

Cookies are deliberately not consulted. Two reasons:

1. Cookies are scoped by **domain, not frame**. Served from a different registrable domain than an
   embedding page, the browser never sends that page's cookie here — the feature would silently do
   nothing.
2. Cookie credentials are CSRF-exposed by construction, since browsers attach them automatically.
   Bearer headers are immune because a browser never adds them unprompted.

### Obtaining a token when embedded

An iframe cannot read its parent's cookies across origins. The parent hands the token down:

```js
// Parent (the embedding application)
frame.contentWindow.postMessage({ tapisToken: token }, INSIGHTS_ORIGIN);

// Insights frontend
window.addEventListener('message', (event) => {
  if (event.origin !== EXPECTED_PARENT_ORIGIN) return;   // never skip this
  token = event.data.tapisToken;                          // memory only, not storage
});
```

Hold it in memory. `localStorage` survives the tab and is readable by any script that achieves XSS.

Embedding also requires the server to permit it — see `FRAME_ANCESTORS` in
[operations](operations.md). Unset, the browser refuses the frame regardless of what the token
does.

### Anonymous is a first-class state

Reads work with no credential at all. The application should render fully for a signed-out visitor
and treat authentication as progressive enhancement, because the public dashboard is the common
case rather than the exception.

## Discovering admin status

There is no `/me` endpoint. Admin state is discovered by attempting an admin-only read:

```
GET /api/admins
  200  → the caller is an admin
  403  → authenticated, not an admin
  401  → no usable credential
```

The distinction matters for the UI: 403 means "signed in, not permitted" and 401 means "not signed
in", and they call for different messages.

## Status codes

| Code | Meaning |
|---|---|
| 401 | Nobody authenticated — absent, malformed, expired, or foreign-tenant token |
| 403 | Authenticated, but not permitted |
| 409 | Conflict, e.g. a duplicate vault name for one account |
| 429 | Rate limited. Honour `Retry-After` |
| 502 | An upstream (Tapis) failure, not the caller's fault |
| 503 | Not ready, or minting attempted with no signing keyset |

A 401 never distinguishes *why* a credential failed. That is deliberate; the reason is in the
server log, correlated by request ID.

## Request correlation

Every response carries `X-Request-ID`. Surface it in error UI — it is what makes a bug report
traceable to a specific log line.

Sending your own `X-Request-ID` is honoured and echoed back, so a frontend can correlate its own
trace with the server's. Values are constrained to `[A-Za-z0-9_-]`, 64 characters, and anything
else is replaced.

## Conventions

- Timestamps are ISO 8601, UTC.
- `GET /api/metrics` accepts `resourceID`, `type`, and `limit` (1–1000, default 1000) and returns
  readings **oldest first**, which is chart x-axis order, having selected the newest `limit` rows.
- IDs are UUIDs.
- The OpenAPI document at `/openapi.json` is generated from the routes and is the source of truth;
  guarded routes carry the bearer scheme.

## Serving the built application

Planned, not yet implemented.

**SPA fallback.** A catchall serves `index.html` for non-`/api` deep links. Safe because Vapor's
router prefers constant path components, so `/api/*`, `/docs`, `/openapi.json`, `/health`, and
`/ready` continue to win.

**Cache headers.** Long `max-age` and `immutable` for hashed bundles; `no-cache` for `index.html`.
Without the latter, clients pin to a stale entry point referencing chunks that no longer exist.

**Build.** A Node stage in the `Dockerfile` emits into `Public/`. The runtime image already stages
`/build/Public`, so nothing downstream changes.

**Root route.** `routes.swift` currently renders the Leaf dashboard at `/`, which is exactly where
`index.html` must go. That collision gets resolved when the frontend lands.

## Development loop

`ng serve` on :4200 with `proxy.conf.json` forwarding `/api` to :8080:

```json
{ "/api": { "target": "http://127.0.0.1:8080", "secure": false } }
```

The alternative — `ng build --watch` straight into `Public/` — loses hot reload but makes
development byte-identical to production. The proxy is the better default.

Set `CORS_ORIGINS=http://localhost:4200` only if you bypass the proxy; through it, requests are
same-origin and no CORS middleware is needed.

## Content-Security-Policy

Only `frame-ancestors` ships today. A fuller policy waits on the bundle's asset origins, because a
wrong `script-src` breaks the application rather than degrading it.

When that policy is written, note that the Leaf dashboard loads daisyUI and ApexCharts from
jsdelivr and the Scalar API reference loads from jsdelivr too. Vendoring them into `Public/` is
preferable to allowlisting a CDN — it removes both the CSP exception and an unpinned third-party
script running with full page privileges.

#icicle-insights# #frontend# #angular# #api# #developer-documentation#
