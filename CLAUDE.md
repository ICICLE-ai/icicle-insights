# ICICLE Insights — working notes

Swift 6.3 / Vapor 4 service collecting open-source impact metrics into PostgreSQL, with Valkey
queues, a public REST API, and an Angular 22 dashboard.

## Orientation

| Read | When |
|---|---|
| [docs/](docs/) | Documentation map, organised on Diátaxis |
| [docs/explanation/architecture.md](docs/explanation/architecture.md) | System map, lifecycles, layout |
| [docs/reference/invariants.md](docs/reference/invariants.md) | **Before changing behaviour** — rules that must stay true |
| [docs/reference/http-api.md](docs/reference/http-api.md) | Routes and their guards |
| [docs/explanation/authentication.md](docs/explanation/authentication.md) | Auth, admins, webhook tokens |
| [docs/reference/test-suite.md](docs/reference/test-suite.md) | What the suite covers, why it might not run |
| [docs/explanation/decisions/](docs/explanation/decisions/) | Why something is the way it is, before changing it |
| [docs/how-to/set-up-the-dashboard-toolchain.md](docs/how-to/set-up-the-dashboard-toolchain.md) | Angular MCP server and the vendor `llms-full.txt` files |
| [TODO.md](TODO.md) | Current state and what is left |

## Commands

```bash
just              # list every recipe, grouped
just run          # dev server
just migrate
just test         # serial, against the `test` database
just fmt          # run before committing
just web          # Angular dev server on :4200
just stack        # full local container stack
```

## Setup that bites

- **`.env` must exist** or the whole suite fails in setup — Tapis configuration is parsed inside
  `configure`. Copy `.env.example`.
- **`DATABASE_TLS=disable`** locally, or every connection fails `sslUnsupported`.
- **Use the staging Tapis tenant for local work** (`icicleai.staging.tapis.io`). It is a separate
  vault, so `init-key` and the vault tests never touch production.
- `TAPIS_BASE_URL` and `TAPIS_TENANT` **move together** — each tenant has its own host. Mixing them
  boots cleanly and then refuses every admin with a bare 403.
- Tapis tokens are short-lived. Unexplained vault failures usually mean expiry.
- **`VAPOR_ENV` sets the environment for every process**, and nothing should pass `--env` on a
  command line — that flag outranks the variable, so pinning it on one process is how a stack ends
  up with processes disagreeing about their own environment. Deployments set `production`; the
  local stacks set `development` in `.env.container` and `docker-compose.yml`.
- **`just dns` is needed once per machine** before the first `just stack`, or containers cannot
  resolve each other.

## Conventions

- **`configure.swift` is the composition root.** It is the only place a concrete backend is chosen.
  Jobs and controllers depend on `SecretProvider` and `FailureNotifier`, never on `TapisClient`.
- **Comments explain *why*.** The codebase's existing comments record rejected alternatives and
  non-obvious failure modes; several encode bugs that cost real debugging. Do not strip them for
  brevity. Add rationale, not restatement.
- Doc-comment every type and non-trivial function. One summary line, then rationale.
- `swift-format` is authoritative; `just fmt` before committing.
- Errors that cross the API boundary conform to `AbortError` with a reason that excludes
  credentials.
- **`docker-compose.yml` and `justfiles/apple-container.just` describe the same stack**, service for
  service, with matching names. Change one and change the other.

## Documentation

Organised on Diátaxis under `docs/`: `tutorials/`, `how-to/`, `reference/`, `explanation/`.

- **One mode per page.** A how-to states no rationale; it links to the explanation. Reference is
  tables, not narrative.
- Every page ends with a tag line carrying exactly one type tag (`#Tutorial#`, `#How-To#`,
  `#Reference#`, `#Explanation#`) and at least one audience tag (`#Administrator#`, `#Developer#`).
- Administrator means whoever runs a deployment, not an end user of the API.
- Keep sentences short. The previous documentation was rewritten specifically because long
  em-dash-chained sentences made it hard to follow.

## Invariants worth stating here

- **The scheduler runs exactly one replica.** Queue workers scale freely; the scheduler does not,
  or scheduled work dispatches twice.
- **Jobs must be retry-safe.** Delivery is at-least-once.
- **Watermarks prevent double counting.** Rolling windows overlap between sweeps;
  `MetricWatermark.countedThrough` records what has already been folded into an all-time total.
  Changing fold logic without understanding this corrupts history silently.
- **Webhook signing keys live in their own `JWTKeyCollection`**, never `app.jwt.keys`. JWTKit falls
  back to the default signer for an unknown `kid`, and Tapis tokens carry one this server never
  registers — sharing a collection would verify real admins against the HMAC key and reject them.
- **Neither authenticator rejects anything.** Each logs in its identity or returns quietly; only
  `Require` produces 401/403. That is what keeps public reads working.
- **`Require`'s predicate is synchronous**, so it cannot query. Admin status resolves during
  authentication and rides on `TapisUser.isAdmin`.
- **Secrets never enter logs or the database.** `Secret` redacts description and reflection;
  `service_tokens` rows hold identifiers and metadata only.
- **`withInsightsApp` must not be renamed.** `VaporTesting`'s generic `withApp` wins overload
  resolution for a single-expression closure and hands the test an empty app.

## Things that only fail on a real boot

`.testing` skips the Tapis tenant key fetch and the vault keyset read, so anything on those paths
is invisible to the suite. Two real bugs hid there: the unwrapped tenant PEM, and the keyset
bootstrap catch-22. Verify such changes against staging, not just `just test`.

## Scope

This is built for ICICLE specifically. `SecretProvider` and `FailureNotifier` are seams because
each had a real second implementation. Do not add abstraction for hypothetical deployments — but
keep Tapis specifics inside `Services/Tapis/` and the two authenticators, so a future adapter is an
addition rather than an untangling.
