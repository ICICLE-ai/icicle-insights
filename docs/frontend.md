# Frontend contract

What a browser client can rely on. The Angular and serving-side sections describe the current
implementation; the OpenAPI document remains the source of truth for individual routes.

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

The frontend resolves a token into memory in this order:

1. `postMessage` from an allowed parent origin;
2. a readable `X-Tapis-Token` cookie on the Insights document;
3. manual paste in the recovery/development control.

An iframe cannot generally read its parent's cookies across origins. A cookie can still be visible
to Insights when Tapis sets a shared-domain, non-`HttpOnly` cookie that covers the pod hostname,
but that deployment detail must not be the only path. The parent handoff is explicit:

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
The server still accepts only the resulting bearer header; it never authenticates from cookies.

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

**SPA fallback.** A catchall serves `index.html` for non-`/api` deep links. Safe because Vapor's
router prefers constant path components, so `/api/*`, `/docs`, `/openapi.json`, `/health`, and
`/ready` continue to win.

**Cache headers.** Long `max-age` and `immutable` for hashed bundles; `no-cache` for `index.html`.
Without the latter, clients pin to a stale entry point referencing chunks that no longer exist.

**Build.** A Node stage in the `Dockerfile` emits into `Public/`. The runtime image already stages
`/build/Public`, so nothing downstream changes.

**Root route.** The Leaf route and assets have been retired. `SPAController` streams Angular's
`index.html` at `/` and extension-free client routes. Unknown `/api/*` and file-like paths stay
real 404 responses rather than becoming misleading HTML 200s.

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

The Angular application vendors its runtime and chart dependencies into the production bundles.
The Scalar API reference at `/docs` still loads from jsdelivr; either vendor it or account for it
explicitly before extending CSP beyond `frame-ancestors`.

#icicle-insights# #frontend# #angular# #api# #developer-documentation#
