# ICICLE Insights — Angular dashboard + admin portal

## Context

The Insights service (Swift/Vapor) currently ships a client-rendered Leaf dashboard
(`Public/dashboard.js`, `Public/dashboard.css`) that fetches four JSON endpoints and draws
ApexCharts. It works, but it is a single 520-line script with no build, no types, no tests, and
no admin surface.

We are replacing it with an Angular 22 application that is Angular-native first — signals,
zoneless, standalone, lazy routes — using **Optimus UI** (`@openng/optimus-ui`, a PrimeNG-compatible
library with `p-*` selectors and the Aura preset) for components and **TanStack Charts**
(`@tanstack/charts/angular`) for visualisation. `Public/dashboard.js` is a *reference for the
domain logic and analytical intent only*; none of its theme, palette, or DOM approach carries over.

Beyond parity, this adds an **admin portal**, gated by a Tapis token, reachable when the app is
embedded in TapisUI. It exposes the guarded POST/PATCH/DELETE routes, admin-only operational
insights, Tapis Vault management, and an interactive nodes-and-edges view of release history.

The intended outcome: one production-ready, WCAG AA, AXE-clean dashboard that serves anonymous
visitors fully and progressively enhances into an admin console for the handful of people who
hold a Tapis admin credential.

---

## Decisions locked

| Question | Decision |
|---|---|
| Token source | Chain: `postMessage` → `X-Tapis-Token` cookie → manual paste. In-memory only. |
| Pod auth mode | `tapis_auth=false` — Traefik passes everyone; the app does its own auth. Keeps anonymous reads first-class. |
| Release graph | **Both** — version-lineage DAG (default) and force-directed network, behind a toggle. |
| Server-side scope | All three: SPA hosting, embedding/pod config, and new admin insight endpoints. |
| First pass | Public dashboard first. Admin portal second, release graph third. |

Backend auth is already implemented and needs no changes — the frontend reads the cookie and
sends `Authorization: Bearer <token>`.

---

## What the codebase actually provides

Verified by reading the source, not assumed.

### API surface (`Sources/Insights/routes.swift`, all under `/api`)

Public reads · admin-guarded writes (`Require.admin`, `Middlewares/Require.swift`):

| Route | Methods | Guard |
|---|---|---|
| `/api/accounts` | GET, POST, `:id` GET/PATCH/DELETE | writes admin |
| `/api/resources` | GET, POST, `:id` GET/DELETE | writes admin |
| `/api/metrics` | GET, POST, `:id` GET/DELETE | writes admin |
| `/api/releases` | GET, POST, `:id` GET/DELETE | writes admin |
| `/api/resources/:resourceID/metrics` | POST | `Require.resourceScoped` (service tokens) |
| `/api/vaults` | GET, POST, `:id` GET/PATCH/DELETE | **admin throughout, reads included** |
| `/api/service-tokens` | GET, POST, `:id/revoke` POST, `rotate-key` POST | admin throughout |
| `/api/admins` | GET, POST, `:id` DELETE | admin throughout |

### Enums (must match exactly — the reference file is stale)

- `Platform` — `github, ghcr, huggingface, npm, pypi`
- `ResourceType` — `container, dataset, model, package, repository, service`
- `MetricType` — `authentications, clones, downloads, forks, likes, pulls, stars, subscribers, views`
  plus all-time twins `authenticationsAllTime, clonesAllTime, downloadsAllTime, pullsAllTime, viewsAllTime`

> `Public/dashboard.js:25` lists `image` in `RESOURCE_ORDER`. **No such `ResourceType` exists.**
> Drop it rather than porting it.

### Contract already written (`docs/frontend.md`)

- Bearer only; the server never consults cookies. Reading the cookie client-side and converting
  it to a header is the frontend's job.
- **No `/me` endpoint.** Admin status is discovered by probing `GET /api/admins`:
  200 = admin · 403 = authenticated, not admin · 401 = no usable credential. The 401/403
  distinction drives different UI copy.
- Every response carries `X-Request-ID`; sending your own is honoured and echoed. Surface it in
  error UI — it is what makes a bug report traceable.
- `GET /api/metrics` accepts `resourceID`, `type`, `limit` (1–1000, default 1000), returns
  **oldest-first**, having selected the newest `limit` rows.
- Anonymous is a first-class state; the app must render fully signed-out.

### Pod deployment (Tapis Pods OpenAPI, `pod_auth`)

The auth callback sets `X-Tapis-Token` cookies at the Pods domain. Pod and TapisUI share the
`tapis.io` registrable domain, so `document.cookie` can see it — **unless Pods sets it `HttpOnly`**.
That is the one unverified assumption in the whole plan and is checked in step 0 below.

Pod networking stanza needs: `tapis_auth: false`, `cors_allow_origins` for the TapisUI origins,
`cors_allow_headers` including `X-Tapis-Token`, and `tapis_ui_uri` for how TapisUI surfaces it.

---

## Two defects inherited from the reference, to fix rather than port

1. **The 1000-row metrics cap silently corrupts portfolio totals.**
   `dashboard.js:496-501` fetches `/api/metrics` unscoped and computes `totalSeries` over the
   result. `MetricController.index` caps at `maxLimit` (1000) and returns *the newest 1000 rows
   across all resources*. Past 1000 readings the "portfolio total over time" is computed from a
   truncated, resource-biased window and is simply wrong — with no visible symptom.
   **Fix:** fetch scoped (`resourceID` + `type`) when a filter is active; for the all-resources
   view, either paginate or state the window explicitly in the panel subtitle. Never imply
   "all time" from a capped fetch.

2. **Stale resource type.** See `image` above.

---

## Architecture

```
src/app/
  core/
    api/            ApiClient, typed DTOs mirroring the Swift Public shapes
    auth/           TokenStore (signal), token sources, adminGuard, authInterceptor
    theme/          theme signal, dark-mode toggle, chart palette tokens
  shared/
    ui/             panel, kpi-tile, empty-state, error-with-request-id
    charts/         thin wrappers over tanstack-chart + paired data tables
    format/         number/date formatters, metric + platform labels
  features/
    dashboard/      public dashboard (filters, KPIs, distributions, reach, trend, releases)
    admin/          lazy-loaded: overview, vaults, service-tokens, admins, catalog
    releases/       lineage DAG + force network, behind a toggle
```

**Token acquisition** (`core/auth`) — priority chain, in-memory only, never `localStorage`:

1. `postMessage` from an origin allowlist (`event.origin` checked before reading — never skip)
2. `X-Tapis-Token` from `document.cookie`
3. manual paste (dev + recovery escape hatch)

**Admin discovery** — probe `GET /api/admins`, map 200/403/401 to `admin` / `authenticated` /
`anonymous`. `adminGuard` is a `CanMatch` on the lazy admin route so the bundle never loads for
non-admins.

**Interceptor** — attaches the bearer header when a token is present, generates and sends
`X-Request-ID`, and captures the echoed value onto error objects for the error UI.

**Theme** — Optimus Aura preset with `darkModeSelector: '.app-dark'`, matched by a Tailwind v4
`@custom-variant dark (&:where(.app-dark, .app-dark *))`. A fresh palette — explicitly *not* the
Catppuccin ramp in `Public/dashboard.css`. Categorical chart colours are declared as CSS tokens so
TanStack picks them up per its themes-and-styling guide, and validated CVD-safe in both schemes.

> Load the `dataviz` skill before writing the first line of chart code.

**Charts** — `Chart` from `@tanstack/charts/angular`, selector `tanstack-chart`, single `[options]`
input carrying `definition` and a **required** `ariaLabel`. Options are immutable: replace the whole
object on change, never mutate. Every chart is paired with a visually-accessible data table as the
exact-value alternative, per the library's accessibility guide.

---

## Task list

Checkboxes are the durable progress record. On approval this file is mirrored to
`web/PLAN.md` in the repo so future sessions resume from it.

### Phase 0 — Verify assumptions (do first, cheap, unblocks everything)

- [ ] Confirm whether the `X-Tapis-Token` cookie is `HttpOnly` (devtools → Application → Cookies
      on a logged-in Tapis session). If it is, the cookie leg cannot work and `postMessage`
      becomes the primary path — the chain already covers this, but it changes what we tell
      TapisUI to do.
- [x] Confirm the deployed origins: pod URL and TapisUI URL. These become `FRAME_ANCESTORS`,
      `CORS_ORIGINS`, and the postMessage origin allowlist.
- [x] Run the API locally (`just run` + `just migrate`) and capture one real response per endpoint
      as test fixtures.

### Phase 1 — Public dashboard  ← first delivery

**Design direction (set 2026-08-20).** An instrument, not a brochure: quiet surface, loud data.
Cool-shifted neutrals rather than warm paper or pure black. Two type roles — mono for anything
the registries treat as an identifier (resource names, versions, counts, dates), sans for prose.
System stacks only, because `docs/frontend.md` prefers vendoring over a font CDN and the CSP is
still unwritten. Signature element: the **platform rail**, which replaced the registry dropdown —
the filter is also a view of how the catalog is distributed. Palette re-validated against the new
surfaces (`#ffffff` light, `#141a22` dark); both modes pass.

**Layout decision (set 2026-08-20).** The section navigator is the production layout. Grid and
Stacked prototypes were removed after comparison; every analytical section now occupies the same
bounded viewport surface. Test Lab remains development-only for genuinely unresolved comparisons,
currently the admin overview's status-first versus triage-first reading order.

- [x] Strip the Angular placeholder (`app.html`, `app.css`) and set up the app shell: header,
      skip link, `<main>` landmark, responsive layout.
- [x] Theme foundation: Optimus preset config, dark-mode selector wired to Tailwind, palette
      tokens, persisted theme signal honouring `prefers-color-scheme` on first load.
- [x] `core/api`: typed DTOs mirroring `Sources/Insights/DTOs/*.swift`, `ApiClient`, error type
      carrying status + `X-Request-ID`.
- [x] `core/auth`: `TokenStore` + the three token sources + interceptor. (Lands here because the
      interceptor is shared; the admin UI comes later.)
- [x] Data layer: resource/account/metric/release signal resources, with the scoped-fetch fix for
      the 1000-row cap.
- [x] Filter bar — snapshot · platform · resource — driving the three scopes
      (all → platform → resource), as `p-select` with proper labels.
- [x] KPI tiles and current reach (horizontal bars), each with its paired data table and
      `ariaLabel`.
- [x] Impact treemap (one block per resource, area = a chosen metric), structure sunburst
      (kind -> registry), and trend (line) charts. The stacked composition bar was cut: it
      encoded resource *count*, so a repository with 3,741 views ranked equal to one with none.
      **Note:** in the current catalog, kind and registry are almost perfectly correlated
      (containers are all GHCR, repositories all GitHub; only `package` splits, npm 7 / PyPI 1),
      so the sunburst's outer ring is close to redundant. It earns itself the moment one kind
      appears on two registries.
- [x] Release list replaced by release cadence aggregated per month, paginated (83 rows -> 15).
- [x] Empty, loading, and error states. Errors quote `X-Request-ID`.
- [x] Accessibility pass: AXE clean, keyboard-only walkthrough, focus visible, contrast checked
      in both themes, no color-alone encoding.
- [x] Unit tests (vitest) for the analytical functions — `totalSeries`, `latestByResource`,
      scoping, label derivation. These are the parts where a silent error is invisible.

### Phase 2 — Admin portal

- [x] `adminGuard` + lazy admin route + admin discovery probe; signed-out / not-admin / admin
      states each with distinct copy.
- [x] Admin overview: collection health (overdue resources from `nextCollectionAt`), vault expiry
      runway, service-token expiry runway. **No new endpoints needed** — `Resource.Public` already
      carries `nextCollectionAt` and `collectionIntervalDays`; `/api/vaults` and
      `/api/service-tokens` already carry `expiresAt`.
- [x] Vault management: list, create, rotate (PATCH), delete. Secret inputs are `type=password`,
      never logged, cleared on submit, with an explicit "this is written to Tapis Vault" notice.
- [x] Service tokens: list, mint, revoke, rotate signing key. The minted token is returned
      **once** (`ServiceToken.Minted`) — the UI must make that unmistakable and offer copy-to-
      clipboard, because a lost token means revoke-and-reissue.
- [x] Admin management: list, add, remove. `isRoot` admins cannot be removed — render disabled
      with an explanation.
- [x] Catalog writes: create/delete accounts, resources, releases, metrics. Signal Forms
      (`@angular/forms/signals`) with schema validation mirroring `Validation.swift`.
- [x] `p-confirmdialog` on every destructive action; `p-toast` for outcomes.
- [x] Session expiry: decode the JWT `exp` client-side to warn before it lapses. Never trust it
      for authorisation — it is a UX affordance only.

### Phase 3 — Release graph

- [x] Semver parser producing major/minor/patch + prerelease, tolerant of non-semver tags
      (`Release.version` is a free string — `v1.2.3`, `2024-05-01`, and `latest` must not crash it).
- [x] Lineage DAG: `treeLayout` (`@tanstack/charts/hierarchy/tree`) with `link` + `dot` + `text`
      marks, release date on the x-axis, colour by major version.
- [x] Force network: `forceLayout` (`@tanstack/charts/network/force`) with the same mark trio.
- [x] Toggle between them, preserving selection across the switch.
- [x] Interaction: focus, tooltip, click-to-filter into the resource scope.
- [x] Accessibility — the hardest surface here. Chart-owned keyboard focus plus a linked table of
      releases; the graph must never be the only way to reach the information.

> **Known limitation to state in the UI:** `forceLayout` is an *eager* transform running a fixed
> number of synchronous simulation ticks. Node positions are computed once — there is no live
> drag-and-settle physics unless we hand-roll it. Interactivity means focus/tooltip/select, not
> dragging.

### Phase 4 — Server-side (Swift)

- [x] SPA hosting: catchall serving `index.html` for non-`/api` deep links. Safe because Vapor's
      router prefers constant path components, so `/api/*`, `/docs`, `/openapi.json`, `/health`,
      `/ready` still win.
- [x] Cache headers: long `max-age` + `immutable` for hashed bundles, `no-cache` for `index.html`
      (without the latter, clients pin to a stale entry point referencing deleted chunks).
- [x] Resolve the root-route collision: `routes.swift:9-11` renders the Leaf dashboard at `/`,
      which is exactly where `index.html` must go. Retire `DashboardController` and the two
      `Public/dashboard.*` files.
- [x] Dockerfile Node build stage emitting into `Public/`. Lines 47-48 already stage
      `/build/Public` into the runtime image, so nothing downstream changes.
- [x] `FRAME_ANCESTORS` set to the TapisUI origin, `CORS_ORIGINS` as needed, plus the documented
      pod networking stanza.
- [x] Dev loop: `proxy.conf.json` forwarding `/api` → `:8080`, wired into `ng serve`.

**Admin insight endpoints**, in ascending order of cost:

- [x] `GET /api/admin/watermarks` — read-only projection of the existing `metric_watermarks`
      table. New controller + DTO, **no migration**.
- [x] `GET /api/admin/queues` — queue depth via `req.redis`, plus scheduler heartbeat.
      **No migration.**
- [x] `job_failures` table + migration + `GET /api/admin/failures`. This is the expensive one:
      **job failures are currently never persisted.** `QueueContext.reportResourceSyncFailure`
      (`Queues/SyncJob+Failure.swift`) logs and fires a Slack alert; nothing is written to the
      database. Needs a new model, migration, and a write in the failure path.

> **Load-bearing constraint for the failure-persistence write.** `FailureNotifier.notify` is
> deliberately `async` but **not** `throws`, because `QueueWorker.runOneJob` awaits
> `job._error(...)` with `try` *before* it clears the job from the queue — a throw there strands
> the job and breaks the worker's run loop. A database write added to the same path must obey the
> identical rule: catch and log, never propagate. Getting this wrong wedges the queue.
> See the doc comment in `Services/Notifications/FailureNotifier.swift`.

---

## Gotchas found the hard way

- **`ng serve` reads `proxyConfig` only at startup.** Editing `angular.json` while it runs leaves
  the proxy off, and every `/api` call is then answered by the SPA fallback: **status 200 with an
  HTML body**. Checking the status code alone cannot detect this — a fallback returns 200 for
  every path. Check `Content-Type`. `toApiError` now names this case (`notJson`) rather than
  letting it surface as "Unexpected token '<'".
- **The dev server can serve a stale module graph** while still regenerating `index.html` per
  request, so the page shows the current HTML shell around an old bundle. Touching a source file
  forces a rebuild; a restart is more reliable.
- **`HttpTestingController` does not run the JSON parser.** A flushed body arrives as though it
  had parsed, so the HTML-instead-of-JSON failure cannot be reproduced through it and is unit
  tested at the `toApiError` level instead.
- **`resource()` loaders start from an effect**, which does not run in a zoneless test until
  `TestBed.tick()`. Without it no request is issued and assertions silently measure an idle store.

## Verification

- `ng build` clean; production budgets in `angular.json` respected (500 kB warn / 1 MB error
  initial). TanStack subpath imports keep unused marks out of the bundle — watch this, since
  `d3-*` is easy to pull in wholesale.
- `ng test` (vitest) green, with real fixtures captured in Phase 0.
- Manual: `just run` + `just migrate` + `ng serve`, walk all three scopes signed-out.
- Admin: paste a real staging Tapis token, confirm the probe resolves to admin, exercise one
  write of each verb, confirm 401/403 render distinctly.
- Embedded: serve behind `FRAME_ANCESTORS`, load in an iframe from the TapisUI origin, confirm the
  cookie is readable and the admin session establishes.
- AXE with zero violations on every route; keyboard-only pass; both themes.
- Reduced motion honoured (`prefers-reduced-motion`) — TanStack motion respects it, but our own
  transitions must too.

## Risks

- **`HttpOnly` cookie** — would invalidate the primary token leg. Phase 0 settles it.
- **Optimus UI v2.0.0 is young.** It is PrimeNG-compatible, but if a component misbehaves the
  fallback is a hand-rolled equivalent, not a fight with the library.
- **TanStack Charts is v0.14.0** — pre-1.0, so the API may move between minors. Pin the exact
  version and keep chart definitions behind our own thin wrappers so a breaking change is a
  localised edit.
- **Iframe + OAuth** — if the token ever expires inside the frame, the re-auth redirect cannot run
  framed (login pages refuse embedding). The UI must detect 401 and tell the user to re-auth in
  the parent tab rather than silently failing.
