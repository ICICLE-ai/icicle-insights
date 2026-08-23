# ICICLE Insights web application

Angular 22 public analytics dashboard and lazy-loaded admin portal for the ICICLE Insights Vapor
service. It uses signals, Optimus UI, and TanStack Charts; the production Docker build emits the
browser bundle into Vapor's `Public/` directory.

## Local development

Run the Vapor API on port 8080, then from this directory:

```bash
npm ci
npm start
```

Open `http://localhost:4200`. The Angular dev server proxies `/api` to `127.0.0.1:8080`, so browser
requests are same-origin and hot reload remains enabled. Proxy configuration is read only at
startup; restart `npm start` after changing `proxy.conf.json`.

## Authentication

Anonymous reads are the default. Admin state is progressive enhancement: an in-memory Tapis token
is resolved from an allowed parent `postMessage`, a readable `X-Tapis-Token` cookie, or the manual
Test Lab control, then sent as `Authorization: Bearer …`. Tokens are never written to web storage.

The lazy `/admin` route probes `GET /api/admins`: 200 is admin, 403 is authenticated without
permission, and 401 is anonymous or unusable. Production authorization always remains server-side.

The Operations view combines catalog scheduling and credential metadata with admin-only queue,
scheduler, watermark, and durable failure projections. Design comparisons stay in the
development-only Test Lab and are never rendered by production builds.

## Verification

```bash
npm test          # Vitest unit/component tests
npm run build     # optimized production build and bundle budgets
npm audit         # dependency vulnerability report
```

Every chart includes an exact table alternative, keyboard support, and an accessible name. Keep
new work AXE-clean in both themes and within the bounded, non-scrolling dashboard viewport.

The implementation plan and durable progress record are in [PLAN.md](PLAN.md). Server deployment,
embedding, cache behavior, and the Tapis Pods networking stanza live in
[`../docs/operations.md`](../docs/operations.md).
