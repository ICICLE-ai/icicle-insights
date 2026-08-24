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
| Authentication, admins, webhook tokens | Shipped |
| Hardening: headers, CORS, rate limits, key rotation | Shipped |
| Failure classification and alerting | Shipped |
| Angular dashboard and admin console | Shipped |
| Request ID middleware | Shipped |
| Documentation | Rewritten on Diátaxis |

## Open

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
`Dashboard/src/app/features/admin/service-token-management.ts`, not from a flow anyone has run.

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

**Full Content-Security-Policy.** Needs the Angular bundle's asset origins settled, and a wrong
policy breaks the application rather than degrading it. The headers that depend on nothing already
ship. The API reference at `/docs` still loads from a CDN; vendor it or allow that origin explicitly
first.

**Tapis `kid` routing / JWKS.** Not possible as Tapis is deployed. Discovery works, but the
advertised key-set URI points back at the tenant record, which serves a single PEM rather than a key
set. There is nothing to route a `kid` against. Revisit only if Tapis starts publishing a real JWKS.

**Webhook token self-renewal.** Tokens expire at 90 days and are replaced by minting a new one and
updating the deployment's secret. A leaked token that could renew itself would never expire, which
removes the only thing expiry buys.

**Angular SSR.** Needs Node at runtime, so a second pod or Node in the runtime image. Worth
reconsidering now the dashboard is public rather than authenticated — the original rationale no
longer holds, even if the conclusion may.

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
