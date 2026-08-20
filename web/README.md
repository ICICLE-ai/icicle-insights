# Insights frontend

Angular application, served by Vapor as static files. **Not scaffolded yet** — this directory
holds the contract so the surrounding repository configuration is already in place.

The API contract this builds against is documented in [`../docs/frontend.md`](../docs/frontend.md).
Read that first; it covers authentication, admin discovery, status codes, and request correlation.

## Why this lives in the backend repository

Vapor serves the built bundle from `Public/` inside its own container image, so there is exactly
one deployable artifact and the frontend must exist at backend-build time regardless of where its
source lives. Separate repositories would not buy independent deployment here — only a Swift
repository without `node_modules` — and the API and UI change together constantly at this stage.

Splitting this directory into its own repository later is straightforward. If that happens, the
frontend publishes a container image and the Dockerfile consumes a pinned tag:

```dockerfile
ARG WEB_TAG=v1.0.0
FROM ghcr.io/icicle-ai/insights-web:${WEB_TAG} AS web
COPY --from=web /dist ./Public
```

Merging two histories back together is the harder direction, which is why it starts here.

## Scaffolding it

```bash
npx @angular/cli@latest new insights-web --directory web --routing --style=css --ssr=false
```

`--ssr=false` is not a preference to revisit casually: server-side rendering needs Node at runtime,
which means either Node in the runtime image or a second pod. This is a dashboard, not a page under
SEO pressure.

Then set the build output so it lands where the Dockerfile expects:

```jsonc
// angular.json → projects.insights-web.architect.build.options
"outputPath": { "base": "dist", "browser": "browser" }
```

## Build contract

| | |
|---|---|
| Build command | `npm run build` |
| Output | `web/dist/browser/` |
| Entry point | `dist/browser/index.html` |
| Deployed to | `Public/` in the runtime image |

`Public/` is gitignored apart from the legacy Leaf dashboard's assets, so built output is never
committed. Those negations in `.gitignore` disappear when the Leaf dashboard does.

## Development

Run Vapor on 8080 and Angular on 4200, proxying the API so requests are same-origin and no CORS
configuration is needed:

```jsonc
// web/proxy.conf.json
{ "/api": { "target": "http://127.0.0.1:8080", "secure": false } }
```

```bash
just run                       # Vapor on :8080
cd web && npm start            # ng serve --proxy-config proxy.conf.json
```

## Apply when the application exists

Four changes, none of which can land before there is a `package.json` to build.

**1. `Dockerfile`** — a Node stage ahead of the Swift build:

```dockerfile
FROM node:22-alpine AS web
WORKDIR /web
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
RUN npm run build
```

and in the staging area, alongside the existing `Public` handling:

```dockerfile
COPY --from=web /web/dist/browser /staging/Public
```

Copying `package*.json` before the sources is what keeps `npm ci` in a cached layer; copying
everything at once reinstalls the whole dependency tree on every source edit.

**2. `Sources/Insights/routes.swift`** — an SPA fallback so deep links resolve, and the root route
freed from the Leaf dashboard. Safe because Vapor's router prefers constant path components, so
`/api/*`, `/docs`, `/openapi.json`, `/health`, and `/ready` still win.

**3. Cache headers** — long `max-age` and `immutable` for hashed bundles, `no-cache` for
`index.html`. Without the second, clients pin to a stale entry point referencing chunks that have
been deleted.

**4. `justfiles/apple-container.just`** — the `build` recipe copies an explicit allowlist into a
temporary context (`cp -R Sources Tests Resources Public`). It needs `web`, excluding
`node_modules`, or the copy is slow and pointless:

```bash
rsync -a --exclude node_modules --exclude dist web "$build_context/"
```

## Content-Security-Policy

Only `frame-ancestors` ships today. Once the bundle's asset origins are settled, write the rest —
and prefer vendoring third-party scripts into the bundle over allowlisting a CDN. The Leaf
dashboard currently loads daisyUI and ApexCharts from jsdelivr, and the Scalar API reference loads
from jsdelivr too; each is an unpinned third-party script running with full page privileges.
