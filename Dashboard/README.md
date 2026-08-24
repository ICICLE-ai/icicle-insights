# ICICLE Insights dashboard

Angular 22 public dashboard and lazy-loaded admin console for the Insights Vapor service.
Signals, zoneless, standalone, lazy routes, with Optimus UI components and TanStack Charts.

## Run it

```bash
just web-install
```

```bash
just web
```

http://localhost:4200. Start the API separately with `just run`.

The dev server proxies `/api` to port 8080, so requests are same-origin and hot reload works. Proxy
configuration is read only at startup; restart after changing it.

## Verify

```bash
just web-test     # Vitest
```

```bash
just web-build    # production bundle and budgets
```

Every chart ships with an exact table alternative, keyboard support, and an accessible name. Keep
new work AXE-clean in both themes and inside the bounded, non-scrolling viewport.

## How it is served

A Node stage in the root `Dockerfile` builds this application and emits the bundle into Vapor's
public directory. The runtime image contains no Node.

Deep links work through an SPA fallback; hashed bundles get immutable cache headers and the entry
point gets `no-cache`.

## Authentication

Anonymous reads are the default and the application renders fully signed out. Administrator
features are progressive enhancement.

A Tapis token is resolved **into memory only**, in order: `postMessage` from an allowed parent
origin, a readable `X-Tapis-Token` cookie, then manual paste. It is sent as
`Authorization: Bearer`. Never write it to web storage.

The `/admin` route probes an admin-only read: 200 means administrator, 403 means authenticated
without permission, 401 means anonymous. Authorization is always enforced server-side; the guard
only decides what to render.

## Where to read more

| Topic | Page |
|---|---|
| Angular MCP server, `llms-full.txt`, conventions | [Set up the dashboard toolchain](../docs/how-to/set-up-the-dashboard-toolchain.md) |
| Serving, tokens, CSP, and why there is no SSR | [The dashboard](../docs/explanation/the-dashboard.md) |
| Every console screen | [Admin console](../docs/reference/admin-console.md) |
| Routes, status codes, conventions | [HTTP API](../docs/reference/http-api.md) |
| Embedding in another application | [Embed the dashboard](../docs/how-to/embed-the-dashboard.md) |

Coding conventions are in [AGENTS.md](AGENTS.md). The implementation record for the rebuild is in
[PLAN.md](PLAN.md).
