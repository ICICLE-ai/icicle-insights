# The dashboard

How the SvelteKit application in `web/` is built, served, fed and authenticated. For developers.

## One pod, no JavaScript runtime

Vapor serves everything: the API under `/api`, and the built frontend as static files.

A Deno stage in the `Dockerfile` builds the app with SvelteKit's static adapter into Vapor's public
directory. The runtime image contains no Deno or Node at all. CI builds the same site in its own
`web` job instead; see [CI pipeline](../reference/ci-pipeline.md).

**A single-page app, not prerendered pages.** Every screen is data, so there is nothing worth
rendering ahead of time. The static adapter writes one `index.html` fallback, and Vapor serves it
for every client-side route.

**No CDN.** A single-region research dashboard does not have the traffic to justify one. Hashed
bundles with immutable cache headers plus ingress compression capture nearly all of the benefit.

## Serving

**SPA fallback.** A catchall serves the entry point for non-API deep links. Vapor's router prefers
constant path components, so the API, the docs and the health probes still win. Unknown API paths
and file-like paths stay real 404s rather than becoming misleading HTML 200s.

**Cache headers.** Everything under `/_app/immutable/` is content-hashed by SvelteKit and cached
for a year. The entry point is `no-cache`, or clients pin to one referencing chunks that are gone.

## Where the numbers come from

Screens render view models shaped like the server's `/api/insights/*` responses: tiles, series and
resource rows. Two sources can produce them.

- **Summary.** The server aggregates in SQL over the whole history.
- **Legacy.** The browser computes the same shapes from `/api/metrics`, one request per metric type.

The app asks `/api/insights/summary` once per visit. A 404 means the server predates it, and the
legacy source takes over. Any other failure is shown, not papered over.

The legacy source inherits two limits. `/api/metrics` returns at most 1,000 readings per request,
so a metric past that has its oldest history cut, and the overview says which metrics. And
all-time totals are one row updated in place, so they get a value and no trend.

Totals carry each resource's newest reading forward day by day. Resources are collected on their
own weekly schedules, so summing only one day's readings would collapse on most days.

## Anonymous is the normal case

Reads need no credential, so the app renders fully for a signed-out visitor. Administration lives
under `/admin` behind its own sign-in.

There is no `/me` route. The console asks `GET /api/admins`: 200 is an administrator, 401 a token
that did not verify, 403 a valid user without admin rights. See [HTTP API](../reference/http-api.md).

## Getting a token

The app holds a token in memory only, from one of three places:

1. a readable `X-Tapis-Token` cookie on the Insights document,
2. a `postMessage` from the parent frame,
3. a token pasted on the sign-in screen, for recovery and development.

**Memory only.** Web storage survives the tab and is readable by any script that achieves XSS.

A message is accepted only from `window.parent` itself, and only from an origin in
`VITE_TRUSTED_PARENT_ORIGINS`, which defaults to `https://icicleai.tapis.io`. The Angular app had
the same check but never configured the list, so an embedded dashboard never received a token.

The server accepts only the resulting bearer header. See [Authentication](authentication.md), and
[Embed the dashboard](../how-to/embed-the-dashboard.md) for the server side of embedding.

## Development loop

`just web` runs Vite on port 5174 and proxies `/api` and `/openapi.json` to Vapor on 8080, so
requests are same-origin and hot reload works. Set `INSIGHTS_API` to proxy somewhere else.

API types in `web/src/lib/api/schema.d.ts` are generated from the running server's OpenAPI
document by `just web-types`. Regenerate after a server change rather than editing them.

## Provenance

Patra imports models and datasets that already live on another registry, so one artifact is often
several resource rows. Each Patra card links its row to the others it names, and the connected
groups of those links are the artifacts. The Provenance page draws one card per group, led by the
row that recorded the links, in a fixed order so the same catalog always draws the same way.

Most model cards produce no link, and that is correct. Their locations name accounts this
deployment does not track. Three datasheets name Hugging Face datasets under `icicle-ai`, so those
do.

## Charts

Every chart has a table view with every value, a keyboard path, and an accessible name. Platform
colours come from one validated palette and follow the platform, never its rank, so filtering
never repaints a line.

## Content-Security-Policy

Only `frame-ancestors` ships today. The bundle serves its own scripts and fonts, but SvelteKit
starts the app from an inline script, so a `script-src` needs that script's hash. SvelteKit's
`kit.csp` setting can emit it. The API reference at `/docs` still loads from a CDN; account for
that before extending the policy.

#icicle-insights# #Explanation# #Developer# #frontend#
