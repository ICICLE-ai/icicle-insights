# ICICLE Insights — Angular dashboard + admin portal

> **This is a durable engineering record, not current documentation.** It tracks the Angular rebuild
> phase by phase, with the reasoning behind each decision preserved — including the ones later
> reversed. Append to it; do not rewrite it.
>
> For how things work today, read [`../docs/`](../docs/). For coding conventions, read
> [AGENTS.md](AGENTS.md). For what is still outstanding, read [`../TODO.md`](../TODO.md).

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

## Phase 5 — UX follow-ups (landed 2026-08-22)

- [x] Vault naming convention: `insights-<platform>-<account>`, derived server-side
      (`Vault.credentialName` in `Sources/Insights/Models/Vault.swift`) rather than typed by the
      admin. Fixes the "which icicle-ai is this" ambiguity — the create dialog's account picker
      is now grouped by registry (`<optgroup>`) instead of a two-step platform-then-account flow,
      and shows a live preview of the generated name.
- [x] Operational watchlist: each attention row has a "Why?" disclosure that expands a plain-
      language reason (`AttentionItem.reason` in `operations.ts`), built from the same fields
      already driving its deadline — no new endpoints.
- [x] Catalog edit: Resource, Release, and Metric each gained an Edit action alongside Delete,
      backed by new `PATCH /api/{resources,releases,metrics}/:id` endpoints. Both edit and delete
      go through a confirmation dialog with a warning message before writing.
      **Accounts were deliberately left create/delete-only** — renaming an account or changing its
      platform would desync the derived Vault credential name and any resource-scoped service
      tokens from what Tapis actually holds, which is a materially different (and riskier)
      operation than correcting a resource's cadence or a release's version.
- [x] Dashboard "Software Releases" cadence table now sits inside the same bordered card chrome
      (`.ins-release-panel`) as every other analytical section, with a heading and subtitle
      matching `app-chart-figure`'s pattern — previously it was a bare `p-table` under a header
      outside any card, which is what read as inconsistent next to Trends/Reach/Lineage.

      The first pass at this only fixed the card chrome and still looked wrong once seen live:
          the header row rendered as plain 13px mixed-case text instead of the intended uppercase
          micro-caps, and the card had ~200px of dead space below the table. Both traced to the same
          cause — `dashboard.css` is scoped by Angular's emulated encapsulation, and `<thead>`/`<th>`
          inside a `p-table` belong to Prime's own internal template, not the dashboard's, so
          `.ins-release-table thead th { ... }` matched nothing at all. Fixed by moving the two rules
          that reach into Prime's internals to `styles.css` (global, unencapsulated — same reasoning
          already documented there for `.ins-chart-table`), and by giving the table
          `[scrollable]="true" scrollHeight="flex"` plus `flex: 1; min-height: 0` on `.ins-release-table`
          so the row area actually fills the card instead of sizing to content and leaving the rest
          of the flex-stretched panel empty. Confirmed via computed styles in a live browser: header
          is `text-transform: uppercase` at the micro size, and table height went from 441px to 549px
          of a 649px panel.

- [x] Trend chart line/area now use monotone cubic interpolation (`curveMonotoneX` via
      `@tanstack/charts/d3/shape`, `d3-shape` added as an explicit dependency rather than relying
      on `@tanstack/charts`'s transitive copy) and a slightly bolder stroke, for a cleaner line at
      conference/projector scale. Monotone rather than natural interpolation specifically because
      it cannot overshoot past a real local min/max — it will not draw a dip or spike the
      underlying counts never had. Confirmed live: lines render visibly smoother, tooltip and
      focus interaction still work.

Verified live in a browser against a real (pre-existing, not seeded this session) dev database
and a real staging admin session: the trend chart, the Software Releases panel in both Cadence
and Lineage modes, the operations "Why?" disclosure, and the Vault create dialog (grouped account
picker, generated-name preview, no free-text name field). Not yet clicked through live: the
Resource/Release/Metric edit dialogs — built on the identical `p-dialog` / `ins-admin-form` /
`ConfirmationService` pattern already confirmed working for the Vault dialog, but not personally
exercised.

- [x] "Reach by resource" bar chart: the ranked colour ramp has 5 steps but `TOP_N` is 10, so bars
      6-10 got the exact fill of bars 1-5 — confirmed via computed styles, not assumed. Bars past
      the fifth now use `color-mix()` to fade the same hue toward the surface instead of repeating
      it verbatim. Separately, the value labels' `x` was the row's own bar-end position plus an
      offset, so numbers trailed bars/names at whatever width they happened to have — a ragged
      staircase rather than the "clean value column" the margin comment already claimed existed.
      Now `x` is the constant `domainMaximum` for every row, so all ten values line up in one
      column regardless of bar length. `top-resources-chart.ts`.
- [x] Release lineage graph: release dots were coloured by semver-major-version bucket while each
      resource's own bullet was coloured by resource ID — two unrelated colour domains sharing
      one 8-hue ramp, with no legend for either, so a single resource's own dots along its own
      lane frequently didn't match each other or its bullet. Confirmed by reading fill attributes
      off 167 plotted dots. Unified both to colour by resource ID, so every dot on one resource's
      lane — bullet included — now shares one consistent hue; two of ten resources still repeat a
      hue (8 colours, 10 lanes) but each lane is internally coherent, which it never was before.
      `release-graph.ts`; the now-unused `parseReleaseVersion` import was removed with it.

## Phase 6 — Reach chart, Cadence table, and a rebuilt release graph (landed 2026-08-22)

A fourth round on the same three surfaces, this time root-caused instead of token-patched (plan:
`~/.claude/plans/eventual-seeking-hellman.md`).

- [x] "Reach by resource" (`top-resources-chart.ts`): removed the ranked-palette cycling entirely
      — every bar is now one static fill (`palette.ranked[0]`), since colour never encoded
      anything here. Names moved to a fixed left margin (`anchor: 'end'`, sized to the longest
      visible name via the existing `estimatedLabelWidth`), so every row reads label→bar→value
      left to right regardless of bar length — no more inside-vs-outside branching. Ported
      `fitChartToViewport()` verbatim from `release-graph.ts` (this chart had no dynamic-height
      logic at all before; its SVG was hard-capped at 460px). Confirmed live: SVG height now
      tracks the card's actual available space (521px measured, previously fixed at 460).
- [x] Cadence table: replaced `<p-table>` with a plain `<table class="ins-chart-table">` — the
      same technology already used by every other paired data table in the dashboard — plus a new
      shared `Paginator` (moved from `features/admin/admin-paginator.ts` to
      `shared/ui/paginator.ts`, since it was always a generic component in the wrong folder).
      Removing `TableModule` dropped the dashboard's lazy chunk from 1.84MB to 891KB. Confirmed
      live: no `p-table` element remains anywhere on the page, header is sticky/uppercase at the
      same tokens as `.ins-chart-table` everywhere else.
- [x] Release graph (`release-graph.ts`, near-total rewrite): replaced the per-resource
      `treeLayout` lineage with a release-centric `forceLayout` cluster. Pick one release; every
      _different_ resource that shipped in the same calendar month (falling back to a ±45-day
      window if that release was alone in its month, capped at 10 nodes by nearest-date when a
      month is crowded — 2025-07 has 11) renders as a big rounded vertex with its name wrapped in
      bold text inside the box (hand-rolled — confirmed no mark in `@tanstack/charts` 0.14.0 wraps
      text in a shape), star-connected to the selected release at the centre. Hover shows that
      vertex's own version and date; click re-centres the cluster on it. `forceLayout` from
      `@tanstack/charts/network/force` turned out to be a real, fully-implemented library feature
      that had simply never been wired up — `web/PLAN.md`'s old Phase 3 checkmark for it was
      stale. New `release-graph.spec.ts` covers the word-wrap algorithm and cluster-membership
      logic (8 tests, all passing). Confirmed live end-to-end: wrapped bold labels render
      correctly including ellipsis-truncation on a very long name, hover tooltips are per-vertex
      correct, click-to-recentre re-simulates the layout, and the sparse/crowded/normal cluster
      sizes all render without console errors.

Verified this round: `ng build` clean after every section, `ng test` green (74 passing, up from
66), prettier clean on every touched file, and — unlike every prior round of this same feedback —
actually driven in a live browser: screenshots plus `javascript_tool` computed-style checks for
every "looks different" claim, not just a glance.

## Phase 7 — Cadence table matches Administration; release graph keyed by period (2026-08-22)

- [x] Cadence table (`dashboard.css`): given a literal target this time ("make it look like the
      Administration tables"), gave it its own `.ins-release-table` class with `.ins-admin-table`'s
      exact values — 0.75rem/1rem cell padding, header `font-weight: 650`, `letter-spacing: 0.06em`
      — rather than `.ins-chart-table`'s lighter dashboard treatment, since the two are different,
      deliberately-scoped design systems and the request this time was specifically to match the
      admin one. The release month cell is `font-weight: 700` (bolder than admin's own 550 row-
      header weight) per explicit request. Confirmed via computed styles: `650`/`0.66px`
      (0.06em)/`12px 16px`/`700` — exact matches.
- [x] Cadence table also gained its own `YYYY-MM` period filter (`cadencePeriods`,
      `selectedCadencePeriod`, `filteredReleaseMonths` in `dashboard.ts`), defaulting to "All
      periods" so the existing steady-vs-bursty overview stays the default rather than narrowing
      to one month unasked — narrowing is opt-in. Caught and fixed a real bug here during
      verification: the paginator's `[total]` was still bound to the unfiltered `releaseMonths()`,
      so picking a period left a stale "Page 1 of 2" showing over a single row.
- [x] "Lineage" tab renamed to "Cluster" (`ReleaseDisplay` type value too, not just the label) —
      the graph stopped being a chronological lineage back in Phase 6.
- [x] Release graph (`release-graph.ts`) reworked again: the hub is now the **period itself**
      (`YYYY-MM`, e.g. "2025-07"), not one arbitrarily-selected resource — every resource that
      released in that period, including the one the user picked from, is a peer around it. The
      selector lists periods, not individual releases. Clicking a peer now scopes the whole
      dashboard to that resource (`resourceSelect`, same action as the paired table's link) rather
      than re-centering the graph, since there's no more "this resource is currently the centre"
      state to hand off. Hover tooltip is now a structured two-row mini table (`Version` /
      `Release`, via `ChartTooltipContent`/`content()` instead of the earlier single-line
      `format()` string) rather than one line of prose. Confirmed live: hub renders as
      "2025-07" in bold inside the blue box, ten differently-named peer resources radiate around
      it with the 11th reported as omitted, and hovering a peer shows a real two-row table with
      the release date correctly in `YYYY-MM`.

Verified: `ng build` clean, `ng test` green (75 passing), prettier clean, and live in the browser
for every change in this phase, including the paginator bug caught only by actually filtering the
table rather than assuming the binding was still correct after the surrounding markup changed.

## Phase 8 — Release graph vertices are circles (2026-08-22)

- [x] Swapped the rounded-`rect` vertex mark for a `dot` (`release-graph.ts`): renamed
      `ReleaseGraphVertex.halfDiagonal` to `radius` — it's now literally the rendered circle's
      radius, not an approximate collision bound — sized as the hypotenuse of the wrapped-text
      block's half-width/half-height, which exactly circumscribes that block (its corners touch
      the circle, guaranteeing the text still fits). `PlacedVertex` dropped its now-unused
      `x1/x2/y1/y2` box-edge fields. As a side benefit, the force simulation's `collide` radius
      and the link `distanceHint` — both already half-diagonal-based — went from a conservative
      approximation (correct for a rectangle's worst-case diagonal) to geometrically exact
      (correct for two circles just touching). Confirmed live: genuine circles, sized per vertex
      by how much wrapped text they hold, no overlaps, tooltip/hover/click still work on the new
      shape.

Verified: `ng build` clean, `ng test` green (75 passing, unaffected — none inspect the renamed
field), prettier clean, live in the browser including hover-tooltip confirmation on a circle.

## Phase 9 — Watchlist filters, form consistency, server-owned all-time totals (2026-08-22)

Four asks, three of them frontend and one crossing into the Vapor service.

- [x] **Operational watchlist is filterable and paginated** (`admin-overview.{ts,html,css}`). The
      panel previously rendered `attention.slice(0, 7)` and closed with a dead-end "N additional
      items are included in the totals above" — items 8+ were unreachable. Replaced by the shared
      `app-paginator` at `pageSize` 8, plus native `<select>` filters for Priority and Affected
      asset, following the dashboard cadence-filter pattern rather than the heavier `p-select`.
      The filter/asset derivation moved into `operations.ts` (`filterAttention`,
      `attentionAssets`) so it is testable next to `summarizeOperations`. Three deliberate
      details: `[total]` binds to the **filtered** length (the same trap that bit the cadence
      table in Phase 7); the heading count stays on the **unfiltered** total, because it is a
      standing KPI and filtering must not make the board look clearer than it is; and
      "nothing matches your filter" is a distinct state from "nothing needs attention" — reusing
      the reassuring all-clear copy there would have been a lie. Asset options come from the
      unfiltered list, or choosing one would delete every other option and strand the user.
- [x] **All seven admin dialogs now match "Add credential"** — the reference form the user picked.
      Its three distinguishing traits, applied uniformly: optimus-themed inputs (`pInputText` on
      every `<input>`, including the ones the reference itself was missing on its date field and
      the token lifetime), a boxed `.ins-admin-secret-notice` opening each form (added to the
      account and both release dialogs), and `.ins-admin-form__hint` under fields whose
      constraint is not obvious. Dialog widths normalised to `31rem`; mint-token keeps `36rem`
      for its one-time-secret textarea. No new CSS classes were needed — every one already
      existed in `admin-records.css`.
- [x] **Every account/resource picker groups by registry** (`option-groups.ts`), extending what
      the vault form was already doing alone. Two accounts can share a name — "icicle-ai" exists
      on both GitHub and npm — and so can their resources; a flat list of those is a coin flip.
      The vault form's bespoke `accountsByPlatform` was replaced by the shared grouper rather
      than left as a fourth copy. Resources reach their platform through their owning account, so
      `resourcePlatformLookup` builds the map once per list instead of scanning per option. A
      resource orphaned from its account lands in a trailing "Unknown registry" group rather than
      vanishing: omitting it would hide a data problem behind an option that simply is not there.
- [x] **Release dates are pickers, not free text** (`release-month.ts` + both release dialogs).
      `<input type="month">` typed as text on several browsers and accepted any year from
      1970–2100; now two native selects, months by name and years **2023–2028**. The year list
      is unioned with the edited record's own year — the seeded ICICLE history predates 2023, and
      a `<select>` bound to a value with no matching option renders blank, which would have
      silently offered to move an old release into range. Dates are read in **UTC**, matching how
      `releasedAt` is stored: reading locally flips a release recorded at midnight on the first
      back into the previous month anywhere west of Greenwich.
- [x] **Metric pickers show bare names** (`metricBaseLabel`), while the metrics table and the
      whole public dashboard keep `metricLabel`'s "Downloads · 30 days". Dropping the qualifier
      everywhere would have reintroduced exactly the bug the `METRIC_LABELS` comment warns about,
      so the window moved into hint text under the picker (`metricWindowNote`) instead of being
      deleted.
- [x] **All-time totals are server-maintained** — the substantive change. `downloadsAllTime` and
      its four siblings are derived running totals, but `MetricController` accepted them like any
      other type, so an admin could type a figure straight into one and the next sweep would
      either overwrite it (`setAllTime`) or accumulate on top of it (`addToAllTime`), silently and
      permanently. Now: `requireRecordable` rejects a `*AllTime` write with 422 on the admin
      create, the webhook create, and the update (both "this row is a total" and "you asked to
      become one"); and every accepted write moves the twin itself — create adds, update applies
      the **difference** (a total accumulates many readings, so restating one moves it by however
      much that reading moved), a type change withdraws from the old twin and adds to the new,
      delete subtracts. `MetricType.isAllTime` is derived from the existing `allTime` switch, so a
      future pair cannot forget to appear in it. - `Metric.adjustAllTime` takes the same `pg_advisory_xact_lock` as `foldDailyIntoAllTime`,
      keyed identically, because API writes now race the sweeps. The lock and the delta apply
      were factored into private helpers so `foldDailyIntoAllTime` does not end up nesting a
      transaction inside its own. - Two guards keep a negative delta from inventing nonsense: a missing row is created only
      for a positive delta, and the stored total floors at zero. - Deleting an all-time row is still allowed — it is the only correction path left once
      editing one is blocked — but the confirm copy now warns that collection rebuilds it from
      the days after its watermark, not from zero. - Known and intentional: for a Hugging Face resource the fold into `downloadsAllTime` is
      temporary, since the Hub reports its own lifetime figure and the sweep replaces it. The
      platform owns that number; a comment at the fold site says so, so it is not "fixed" later.

Verified: `just test` green (**195 passing**), `ng build` clean, `ng test` green (**121 passing**,
up from 75), `swift-format` and prettier clean.

One existing test needed a genuine correction rather than an adjustment to fit: the webhook
rate-limit test in `HardeningTests` counted _every_ metric row to prove "two landed, the third did
not". Accepted readings now also maintain a `downloadsAllTime` row, so it counts the posted type
instead — which is what the assertion always meant.

**Not verified in a browser.** The admin area requires a live Tapis session and there is no
development bypass by design, so the seven dialogs, the pickers, and the watchlist could not be
clicked through here. In place of that, `admin-overview.spec.ts` renders the panel against a
stubbed `AdminStore` and asserts the behaviours the browser pass would have checked: paging
instead of truncation, the paginator tracking the _filtered_ count, both filters, the two distinct
empty states, the expanded reason row closing on a filter change, and the heading count staying
unfiltered. The public dashboard was confirmed live — unbroken, console clean, all-time labels
still qualified. The remaining visual pass across the dialogs needs a signed-in session.

## Phase 10 — Registry scopes in the form pickers, and a repainted registry palette (2026-08-23)

- [x] **Form pickers group by registry _scope_, not raw registry** (`option-groups.ts`, now
      `groupByPlatformScope`). The optgroups follow the same taxonomy the dashboard's registry
      picker uses via `platformScopes`, so npm and PyPI collapse under one "Packages" heading
      instead of standing apart — one vocabulary across the app rather than two.
      - Headings carry the scope's description the same way the dashboard does:
        `Packages · npm + PyPI`. The description is computed from the registries **actually
        present**, so a catalog holding only npm packages reads `Packages · npm` rather than
        promising PyPI options that are not in the list.
      - Collapsing re-merges two registries a picker still has to tell apart, which was the whole
        reason for grouping. So options inside a *multi-registry* scope carry their own registry
        as a suffix — `icicle-ai · npm` beside `icicle-ai · PyPI`. Under a single-registry scope
        the suffix is omitted: "aardvark · GitHub" under a heading that reads "GitHub" is noise.
      - Feeding `platformScopes` the canonical `PLATFORM_ORDER` rather than discovery order keeps
        headings in the same sequence on every screen regardless of what the catalog holds.
- [x] **Registry palette repainted.** The old one was brand-accurate and measurably broken as a
      categorical set: GitHub's near-black sits at L 0.28 with chroma 0.013, failing both the
      lightness band and the chroma floor — in a row of coloured bars it read as "no colour
      assigned" rather than as GitHub. Dark mode had the same defect inverted (near-white).
      - The five registries now draw their steps from the app's existing validated series ramp,
        which is a *reuse*, not a coincidence: same ramp, different semantic role. Association is
        kept where a registry has a real colour — yellow for Hugging Face, blue for PyPI, violet
        for GHCR. npm takes magenta rather than the ramp's red because `PLATFORM_ORDER` puts it
        immediately after Hugging Face, and red against that yellow fails the normal-vision floor
        in dark mode (ΔE 13.0 against a floor of 15). GitHub takes aqua for the plain reason that
        it has no chromatic brand colour to honour.
      - Computed, not eyeballed: `validate_palette.js` passes every check in **both** modes on
        the adjacent pairlist — worst CVD ΔE 13.0 light / 13.2 dark (target 8), worst
        normal-vision ΔE 19.6 light / 19.3 dark (floor 15). Four earlier candidates were rejected
        by the validator, including two that looked fine.
      - Worth knowing before anyone tries to "fix" the remaining warning: **no five-hue set can
        clear the all-pairs floors** — the reference palette's own documentation records that past
        three slots no ordering does. Three light-mode steps sit below 3:1 on white; the
        documented relief is a visible label, and both the registry picker and the rail print the
        registry name beside every bar, so the obligation is met. The adjacent pairlist is the
        right one here anyway: the bars are a vertical list, each neighbouring the next.

Verified: `ng test` green (**125 passing**), `ng build` clean, prettier clean, and live in the
browser in both themes — the picker renders GitHub/GHCR/Hugging Face as distinct hues with
`Packages · npm + PyPI` showing its two-segment npm→PyPI bar, computed styles confirmed to resolve
to the new tokens against each theme's surface, console clean.

One test expectation was wrong and the code was right: the first draft asserted a
`Packages · npm + PyPI` heading for a fixture containing only npm resources. `platformScopes`
describes the registries present, which is the better behaviour — the test was corrected, not the
code.

## Phase 11 — Cleanup pass (2026-08-23)

A quality pass over the changed code — reuse, simplification, dead code, and a visual sweep. No
behaviour was meant to change, and none did; the one fix that alters what you see was a genuine
contrast defect.

- [x] **Five copies of clamp-and-slice collapsed into one `pageSlice`** in
      `shared/ui/paginator.ts`, beside the component whose clamp they were duplicating. Three of
      the five also hardcoded the page size as a bare `10`. This is the pattern that produced the
      cadence-table bug back in Phase 7 — the component and its pager each deciding independently
      which page was current — so the fix belongs next to `Paginator`, not repeated per table.
      `DEFAULT_PAGE_SIZE` now feeds both the helper's default and the component's `pageSize`
      input, and `pageSlice` additionally clamps *low*, which the copies did not.
- [x] The release-cadence page size, previously written as `8` in both the template binding and
      the component, is one `CADENCE_PAGE_SIZE` constant.
- [x] `groupByPlatformScope` and `resourcePlatformLookup` narrowed to module-private — both were
      exported but only ever called by the two wrappers in their own file.
- [x] Two pure-delegation methods in `metric-management.ts` became field aliases, matching the
      `formatDate` convention already in that file.
- [x] **A real contrast bug, fixed:** the dev-tools "Test lab" trigger set `color: #ffffff`
      against `background: var(--ins-ink)`. `--ins-ink` inverts between themes; the literal did
      not, so in dark mode the button rendered white-on-white at **1.09:1** — effectively
      invisible. Pairing it with `var(--ins-surface)` inverts both together: **19.22:1** light,
      **15.99:1** dark, and the blue hover state stays legible in both. It was the only
      white-on-`--ins-ink` pairing in the app.
- [x] Two comments added where the code invites an incorrect "simplification":
      `MetricController.update`'s branch is **not** redundant — because `adjustAllTime` floors at
      zero, withdrawing-then-adding is not equivalent to one net delta (100→175 against a total
      of 50 is 125 one way, 175 the other); and `delete`'s `isAllTime` guard matters where a
      duplicate total exists, which the previously-unguarded API allowed.

Verified by **exit code** rather than by grepping output: prettier, `tsc --noEmit`, `ng build`,
`ng test` (**132 passing**), `swift build`, and `just test` (**195 passing**) all exit 0. The
contrast fix was confirmed live in the browser by computing the ratio in both themes.

Two process notes worth keeping:

- An earlier `npm run build` was reported clean on the strength of a `grep -c` for `^Error|error
  TS`. Angular prints `✘ [ERROR]`, so the grep matched nothing and a **failing build looked like
  a passing one**. Check the exit code.
- The failing build in question was caused by a CSS comment inside a `styles:` template literal
  that contained backticks around `--ins-ink`, silently terminating the literal. The dev server
  had been serving stale output for some time as a result — `preview_logs` says so immediately
  and should be the first thing checked when an edit does not appear in the browser.

**Untracked files worth a decision** (left in place, not deleted): `web/:memory:.ses` is 51 bytes
of stray session state from a tool handed `:memory:` as a path, and `web/sas.json` is empty. Both
look accidental and neither is referenced anywhere; they are also not gitignored, so they would
join the next broad `git add`.

## Phase 12 — Registry scopes, tab names, and production readiness (2026-08-23)

- [x] **Registry pickers name what a registry publishes**, not the brand. `PLATFORM_GROUPS` now
      covers every provider — Repositories (GitHub), Containers (GHCR), Models & Datasets
      (Hugging Face), Packages (npm + PyPI) — so the dashboard scope picker and the admin form
      `<optgroup>`s share one vocabulary and Packages sits beside its neighbours as a peer rather
      than as the one odd multi-registry entry. `spansMultipleRegistries` replaces
      `isPlatformGroup` at the one call site that cared, because with every scope now a group the
      old predicate stopped separating anything.
      - Models and Datasets stay merged. Both live on Hugging Face, and this taxonomy keys on the
        registry; splitting them is a resource-type question, which would be a different filter
        dimension rather than a longer list. Recorded in the `PLATFORM_GROUPS` comment so the
        next person does not try it.
- [x] **Dashboard tabs renamed** to a parallel set: **Portfolio · Top Resources · Trends ·
      Releases**. "Headline" named importance rather than content and was the default tab, so it
      was the first word a reader saw and told them nothing. "Top Resources" avoids echoing the
      `RESOURCE` scope picker directly above it and is honest that the panel shows 10 of 43. The
      panel heading "Who carries the reach" became "Which resources lead" — nothing on the page
      defined "reach", and the metric behind it is user-selectable anyway.
- [x] **Acknowledgment replaced** with the approved NSF wording and award number (OAC 2112606),
      retiring the placeholder comment that asked for it.
- [x] **Release months displayed a month early.** A release is stored as the first instant of its
      month (`2023-04-01T00:00:00Z`); `formatAdminDate` has no `timeZone`, so in any zone behind
      UTC it rendered as March 31 — every one of the 81 rows, off by one month. `dashboard.ts`
      already groups on UTC parts and comments on the hazard, so the admin table was the lone
      deviation. Added `formatAdminMonth` (UTC, month + year), which also drops a day the data
      never had and matches the column's own "Release month" header.
- [x] **`Dockerfile` no longer pins `--env production` on CMD.** The flag outranks `VAPOR_ENV` in
      `Environment.detect`, which is the drift CLAUDE.md calls out as an invariant and which both
      `docker-compose.yml` and the container justfile avoid deliberately, each with a comment. The
      image now defaults via `ENV VAPOR_ENV=production` — a variable a deployment can override the
      ordinary way, rather than a flag nothing can.

Production build verified as the Dockerfile runs it (`npm run build --output-path=…`): exit 0,
493 kB initial against a 600 kB warning budget, favicon and `index.html` emitted. Vapor's
`SPAController` already handles deep links, excluding `api`/`docs`/`health`/`ready` and rejecting
file-like paths so a missing chunk 404s instead of returning HTML.

Verified: `ng build`, `ng test` (**136 passing**), prettier, `swift build`, `just test` (**195
passing**) — all exit 0. Admin screens walked in the browser against live data; the grouping's
value showed up immediately, since the catalog holds five accounts all named `icicle-ai`, one per
registry.

Known and deliberate, not yet done:

- The logos in `assets/` use live `<text>` in Montserrat and Proxima Nova, and the app loads no
  webfonts. They need outlining before use or they will render in a fallback face. The favicon
  there is a 1355×1187 PNG despite its `.ico` extension; the committed multi-size ICO is better.
- The dev-tools "A/B Test lab" is `@if (devMode)`-gated and never renders in production, though
  its code is still bundled in a chunk nothing requests. It also holds the manual token paste
  used to sign in locally, so removing it costs that.
- Catalog → Metrics is the one dialog not yet verified in a browser.

## Phase 13 — Brand mark, dev-tool removal, and bare metric pickers (2026-08-23)

- [x] **A/B Test Lab removed** — `DevTools`, `ExperimentPicker`, `DevSessionControl`, and
      `ExperimentStore` are all deleted. It was `@if (devMode)`-gated and never rendered in
      production, but its code was still bundled in a chunk nothing requested. The store's own
      doc said it "exist[s] exclusively behind the development Test Lab", so with the Lab gone
      `adminOverview()` could only ever return its default and the two `.is-triage-first` rules
      were unreachable — removed with it. Note this also removes the manual token paste used to
      sign in locally; a Tapis session now has to arrive the normal way.
- [x] **Brand mark is the ICICLE glyph**, cropped out of the institute wordmark and drawn as a
      CSS mask so it takes the surrounding ink colour and follows the theme — the source artwork
      is white and an `img` of it would vanish on the light surface. The box is now a square
      matching the theme button rather than sized to two lines of text, and the product name
      moved to `aria-label`, since a mark with no visible text would otherwise leave the masthead
      unlabelled.
- [x] **The favicon was Angular's default logo.** `web/public/favicon.ico` carried the pink `A`
      shield that ships with `ng new`; the ICICLE artwork the Leaf dashboard used (`assets/`,
      md5 `2dca3fd…`) had been lost in the rewrite. Restored. It is a 1355×1187 PNG behind an
      `.ico` name — which browsers accept and the old dashboard shipped — but it is worth
      re-exporting as a real multi-size icon at some point.
- [x] **Dashboard metric pickers show bare names**, extending the earlier form-only decision.
      This could not be done by stripping labels alone: both pickers offer `downloads` *and*
      `downloadsAllTime`, so two options would have read "Downloads" with nothing to separate
      them. They are now grouped under "Latest window" and "All time" headings, the same trade
      the registry pickers make — the heading carries the qualifier so the option does not have
      to. `metricBaseLabel` now strips the `AllTime` suffix, and its spec pins the twin collapse
      precisely because two pickers depend on the grouping to stay unambiguous.
      - Chart legends and subtitles keep `metricLabel`. That is where the figures are, and where
        both Downloads series appear at once, so the window has to be stated.

Verified: `ng build`, `ng test` (**137 passing**), prettier, `swift build`, `just test` (**195
passing**) — all exit 0. Both pickers and the brand mark checked in the browser in dark and light.
