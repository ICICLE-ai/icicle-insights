# ICICLE Insights — working notes

Swift 6.3 / Vapor 4 service collecting open-source impact metrics into PostgreSQL, with Valkey
queues, a public REST API, and a dashboard.

## Orientation

| Read | When |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System map, lifecycles, layout |
| [docs/invariants.md](docs/invariants.md) | **Before changing behaviour** — rules that must stay true |
| [docs/api-authentication.md](docs/api-authentication.md) | Auth, admins, webhook tokens, config |
| [docs/testing.md](docs/testing.md) | What the suite covers, why it might not run |
| [docs/decisions/](docs/decisions/) | Why something is the way it is, before changing it |
| [TODO.md](TODO.md) | Current state and what is left |

## Commands

```bash
just run          # dev server, environment = development
just migrate
just test         # serial, against the `test` database
just fmt          # swift-format, run before committing
just fmt-check
```

## Setup that bites

- **`.env` must exist** or the whole suite fails in setup — `TapisConfig.fromEnvironment()` throws
  inside `configure`. Copy `.env.example`.
- **`DATABASE_TLS=disable`** locally, or every connection fails `sslUnsupported`.
- **Use the staging Tapis tenant for local work** (`icicleai.staging.tapis.io`). It is a separate
  vault, so `init-key` and the vault tests never touch production.
- `TAPIS_BASE_URL` and `TAPIS_TENANT` **move together** — each tenant has its own host. Mixing them
  boots cleanly and then refuses every admin with a bare 403.
- Tapis tokens are short-lived. Unexplained vault failures usually mean expiry.

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

## Things that only fail on a real boot

`.testing` skips the Tapis tenant key fetch and the vault keyset read, so anything on those paths
is invisible to the suite. Two real bugs hid there: the unwrapped tenant PEM, and the keyset
bootstrap catch-22. Verify such changes against staging, not just `just test`.

## Scope

This is built for ICICLE specifically. `SecretProvider` and `FailureNotifier` are seams because
each had a real second implementation. Do not add abstraction for hypothetical deployments — but
keep Tapis specifics inside `Services/Tapis/` and the two authenticators, so a future adapter is an
addition rather than an untangling.
