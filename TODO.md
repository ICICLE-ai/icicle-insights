# TODO

Current state and what is left. Rationale for decisions already made lives in
[docs/explanation/decisions/](docs/explanation/decisions/); this file tracks work, not reasoning.

## State

Deployed and running at `insights.pods.icicleai.tapis.io`, collecting from GitHub and Hugging Face
across 110 resources under 5 accounts.

| Area | State |
|---|---|
| Collection: GitHub repositories and accounts | Shipped |
| Collection: Hugging Face | Shipped |
| Collection: GHCR, npm, PyPI | Registered in the catalog, no collector |
| Collection: Patra (catalog, deployments, provenance) | Shipped on `patra`, not yet merged or deployed |
| Authentication, admins, webhook tokens | Shipped |
| Hardening: headers, CORS, rate limits, key rotation | Shipped |
| Failure classification and alerting | Shipped |
| SvelteKit dashboard and admin console | Built; admin console not yet walked signed in |
| Request ID middleware | Shipped |
| Documentation | Rewritten on Diátaxis |

## Open

### Walk the new admin console signed in, then fix the docs that describe it

The SvelteKit console replaced the Angular one. Its screens were checked signed out (the sign-in
gate, a rejected token) and every admin endpoint's response shape was checked against the code, but
nobody has yet signed in and walked it. Until someone does:

- walk every section against [Admin console](docs/reference/admin-console.md), which was written
  from the new components;
- rewrite [Administering Insights](docs/tutorials/administering-insights.md), which still walks the
  Angular tabs and carries a notice saying so;
- retake `assets/screenshots/`, which still show the Angular UI (the README embeds two). Capture
  from staging or production, not a dev database, so the figures are real;
- run an accessibility check (axe) in both themes; the Angular app's AXE-clean status did not carry
  over automatically.

Vault create, replace and delete, and signing-key rotation, write to Tapis. Try them against the
staging tenant, never a local stack pointed at production.

### Confirm the embed token handover

`VITE_TRUSTED_PARENT_ORIGINS` defaults to `https://icicleai.tapis.io`. The Angular app never set its
equivalent, so no embedded dashboard has ever received a token this way. Confirm from TapisUI that
the ADMIN state appears after the parent posts a token.


### Finish the documentation pass

The Diátaxis rewrite landed in `8059515`. 43 pages under `docs/`, all links resolving, all tags
well formed, every route and guard checked against the live deployment's OpenAPI document. What
remains is verification that needed a running system, not writing.

**Walk the console against the docs.** The console pages were written from the Angular components,
not from the running UI. That shortcut is what let four wrong claims through the first time, and
one of them — the vault credential form having a name field it does not have — survived until a
human spotted it. Sign in and check each screen and form against
[docs/reference/admin-console.md](docs/reference/admin-console.md) and the administrator how-tos.

**Run the stack end to end.** `just build` is verified, as are `db`, `valkey`, `stop` and the
recreate path. `just stack` and `just test` have never been run in the `docs` worktree, which has
no `.env`. Copy one from a checkout that has it — do not copy the main one wholesale, the container
stack expects local database values — and confirm the tutorials work as written.

**Then push and open the PR.** Six commits sit unpushed on the `docs` branch.

Conventions for any new page are in [CLAUDE.md](CLAUDE.md) under Documentation. Follow them for
docs written alongside other work, so the set stays consistent while this is unfinished.

### Verify Patra against a real boot

This documentation pass (the last task of the Patra platform work) touched no code and ran neither
`just migrate` nor `just run` — its brief scoped it to docs only. Two things it describes remain
unverified against a live system:

- **The console flow.** Registering the `icicleai` account on `patra`, running `just collect
  --force`, and confirming 29 resources, 43 cards, and readings of 52 / 16 / 1 on MegaDetector,
  ResNet50, and MobileNetV2 — all written from source, none walked by hand.
- **The dashboard.** The Patra platform hue and the Provenance tab's two-line node labels, in both
  the light and dark theme. `provenance-graph.spec.ts` covers the layout mechanism, but nobody has
  loaded the running page against seeded or live data.

Model card provenance is expected to render empty either way: Patra's real `location` values
resolve for most of its live model cards, but none name an account this deployment tracks (its
Hugging Face URLs are third-party, and its GitHub URLs name `camera_traps`, not the `Camera_Trap`
Insights collects). That is documented behaviour, not something this check would be looking to
fix.

Datasheet provenance is different: three datasheets (CAN Benchmark, the HLO feature dataset, and
the Organization SIC Code dataset) carry a Hugging Face `alternate_identifier` or
`related_identifier` naming a dataset under the `icicle-ai` account Insights already tracks, so
those three edges are expected to render — the one part of the graph this check should actually
see filled in.

### `ResourceType.agent` has no publisher

`agent` exists in the `resource_type` enum and every dashboard picker and admin form lists it, so
it can be registered by hand today. Nothing collects one: no Patra endpoint and no other collector
publishes an agent resource. `/agent-tools/*` are AI tooling routes, not agent records. The catalog
job gains a third endpoint — beside `/modelcards` and `/datasheets` — if and when Patra ships one.

### Verify the production signing keyset

`service-token init-key` must have run against the **production** vault, not just staging — they
are separate vaults and a keyset does not carry over. The console shows no issued tokens, so this
is untested in production.

Confirm by checking a production boot log for `Webhook token signing keys loaded.` If instead it
says `No webhook token signing keyset found`, run `init-key` once and restart.

### Document minting a token through the UI, once a service account protocol exists

**Blocked on:** deciding how deployed ICICLE services register themselves — the service account
protocol. Nothing to do until that is settled.

No resource of kind `service` is registered anywhere, so the Service tokens screen has only ever
shown its empty state: *"No service resources are registered."* That means the console half of
[Issue a service token](docs/how-to/issue-a-service-token.md) was written from
the Angular console's source, not from a flow anyone has run. The SvelteKit console's form
(`web/src/routes/admin/service-tokens/+page.svelte`) keeps the same three fields.

The form fields named there — Resource, Deployment label, Lifetime in days — are correct as source,
and `ServiceTokenIssuer.swift:61` does enforce `resource.type == .service` server-side. What is
unverified is everything around them: what the populated screen looks like, how the minted token is
presented and copied, what the token list shows once a row exists, and what revoking looks like in
the UI.

When the protocol lands:

- register a real service resource and mint a token through the console;
- rewrite the console steps in that how-to against the actual flow;
- replace `assets/screenshots/admin-service-tokens.png`, which currently shows the empty state, with
  a populated list;
- check whether the empty-state wording still belongs in `docs/reference/admin-console.md`.

Treat the current console steps as provisional until then. The CLI half is verified and can be
relied on.

### Collectors for GHCR, npm, and PyPI

All three can be registered and are re-booked normally, but the dispatcher logs and skips them.

- A GHCR prototype exists that scrapes HTML. It needs a decision about whether that workload belongs
  on the `metrics` queue or its own, given its very different failure profile and latency.
- npm and PyPI both publish download APIs and should be straightforward.

See [Add a collector](docs/how-to/add-a-collector.md).

### Metric series pagination

`/api/metrics` caps at 1000 rows, newest first. At roughly 103 rows per weekly sweep that is about
ten weeks of trailing history. Per-type fetches or downsampling is the follow-up when it gets tight.

### Fetch-on-create

`ResourceController.create` already dispatches a sync and books the next collection. The path is
live; nothing outstanding unless creation-time collection needs to become optional.

## Deliberately not doing

**Full Content-Security-Policy.** The bundle is same-origin, but SvelteKit starts the app from an
inline script, so `script-src` needs its hash (`kit.csp` can emit it). A wrong policy breaks the
application rather than degrading it. The headers that depend on nothing already
ship. The API reference at `/docs` still loads from a CDN; vendor it or allow that origin explicitly
first.

**Tapis `kid` routing / JWKS.** Not possible as Tapis is deployed. Discovery works, but the
advertised key-set URI points back at the tenant record, which serves a single PEM rather than a key
set. There is nothing to route a `kid` against. Revisit only if Tapis starts publishing a real JWKS.

**Webhook token self-renewal.** Tokens expire at 90 days and are replaced by minting a new one and
updating the deployment's secret. A leaked token that could renew itself would never expire, which
removes the only thing expiry buys.

**Server-side rendering.** SvelteKit could render pages on a server, but that needs Deno or Node at
runtime, so a second process or a bigger image. The dashboard ships as static files instead; every
screen is data, and nothing needs search indexing.

**Response compression.** The ingress may already handle it. Nobody has checked; this is an open
question rather than a decision.

**Finer rate limiting.** Per-address on the API and per-token on the reporting route are in.
Per-route budgets and burst allowances wait for evidence that the flat limits are wrong.

## Known rough edges

**Rotation across a restart is only checked by hand.** The suite proves rotation is additive in
memory. Only a restart proves the retired key was persisted, and nothing automates that.

**The scheduler's clocks are not asserted.** Jobs are driven directly through a test queue context.
That the hourly and monthly registrations are wired correctly is verified by observation, not by a
test.
