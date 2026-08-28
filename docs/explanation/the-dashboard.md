# The dashboard

How the Angular application is built, served, and authenticated. For developers.

## One pod, no Node at runtime

Vapor serves everything: the API under `/api`, and the built frontend as static files.

A Node build stage in the `Dockerfile` compiles Angular and emits the bundle into Vapor's public
directory. The runtime image contains no Node at all.

**No server-side rendering.** SSR would put Node in the runtime image or add a second pod. This is
a dashboard, not a page that needs search indexing.

**No CDN.** A single-region research dashboard behind an ingress does not have the traffic profile
to justify one, and it adds a cache-invalidation failure mode. Hashed bundles with immutable cache
headers plus ingress compression capture nearly all of the benefit.

## Serving

**SPA fallback.** A catchall serves the application's entry point for non-API deep links. This is
safe because Vapor's router prefers constant path components, so the API, the docs, the OpenAPI
document, and the health probes all still win. Unknown API paths and file-like paths stay real 404s
rather than becoming misleading HTML 200s.

**Cache headers.** Long-lived and immutable for hashed bundles; no-cache for the entry point.
Without the second, clients pin to a stale entry point referencing chunks that no longer exist.

## Anonymous is the normal case

Reads need no credential, so the application renders fully for a signed-out visitor. Administrator
features are progressive enhancement, not a gate.

There is no `/me` route. Admin state is discovered by attempting an admin-only read and reading the
status code. See [HTTP API](../reference/http-api.md).

## Getting a token

The frontend resolves a token into memory, in this order:

1. a `postMessage` from an allowed parent origin,
2. a readable `X-Tapis-Token` cookie on the Insights document,
3. manual paste, for recovery and development.

**Memory only.** Web storage survives the tab and is readable by any script that achieves XSS.

The parent handoff is the path that works everywhere. An iframe cannot generally read its parent's
cookies across origins; the cookie route only works when Tapis sets a shared-domain, non-HttpOnly
cookie covering the pod hostname, which is a deployment detail and must not be the only path.

```js
// Parent
frame.contentWindow.postMessage({ tapisToken: token }, INSIGHTS_ORIGIN);

// Insights
window.addEventListener('message', (event) => {
  if (event.origin !== EXPECTED_PARENT_ORIGIN) return;   // never skip this
  token = event.data.tapisToken;
});
```

The origin check is not optional. Without it any page that can reach the frame can inject a token.

The server accepts only the resulting bearer header. It never authenticates from a cookie — see
[Authentication](authentication.md) for why.

Embedding also needs the server's permission. See
[Embed the dashboard](../how-to/embed-the-dashboard.md).

## Development loop

The dev server proxies `/api` to Vapor, so browser requests are same-origin and hot reload keeps
working. No CORS configuration is needed through the proxy.

The alternative — building straight into Vapor's public directory on watch — makes development
byte-identical to production but loses hot reload. The proxy is the better default.

Proxy configuration is read only at startup. Restart after changing it.

## The provenance graph

Patra imports models and datasets that already live in another registry. The Provenance tab's
`provenance-graph.ts` draws one node per `Resource` and one edge per link a Patra card recorded
between them, so the same real artifact under two registries reads as one connected pair, not two
disconnected catalog rows. There is no hub node: a resource earns a place in the graph only by
taking part in an edge, and its label is its name over `platformLabel(platform)`.

**Model card links mostly render empty, and that is correct, not a bug.** Patra resolves a
`location` for most of its live model cards, but none name an account this deployment tracks. Its
Hugging Face URLs belong to third-party accounts, and its GitHub URLs name
`ICICLE-ai/camera_traps`, a different repository from the `ICICLE-ai/Camera_Trap` Insights
actually collects.

Datasheets are different: three of Patra's live datasets carry a Hugging Face identifier under the
`icicle-ai` account Insights already tracks (CAN Benchmark, the HLO feature dataset, and the
Organization SIC Code dataset), so those three do produce edges. The rest fill in once someone
registers the remaining matching accounts and resources.

## Accessibility is a gate, not a goal

Every chart ships with an exact table alternative, keyboard support, and an accessible name. New
work stays AXE-clean in both themes.

A chart without a table alternative is unreadable to a screen reader, and this is a public dashboard
for a publicly funded institute.

## Content-Security-Policy

Only `frame-ancestors` ships today.

A fuller policy waits on settling the bundle's asset origins, because a wrong `script-src` breaks
the application rather than degrading it. The Angular application vendors its runtime and chart
dependencies, but the API reference at `/docs` still loads from a CDN. Vendor that or account for it
explicitly before extending the policy.

#icicle-insights# #Explanation# #Developer# #frontend#
