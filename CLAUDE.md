# ICICLE Insights: working notes

A Swift 6.3 and Vapor 4 service that collects usage metrics for ICICLE's open-source work into
PostgreSQL. Jobs run on Valkey queues. A SvelteKit dashboard in `web/` is built with Deno and served
by the same process.

## Where to look

| Read | When |
|---|---|
| [docs/README.md](docs/README.md) | The documentation map |
| [docs/explanation/architecture.md](docs/explanation/architecture.md) | Processes, request path, source layout |
| [docs/explanation/how-collection-works.md](docs/explanation/how-collection-works.md) | **Before touching a collector, the sweep or all-time totals** |
| [docs/reference/http-api.md](docs/reference/http-api.md) | Routes and who may call them |
| [docs/reference/configuration.md](docs/reference/configuration.md) | Every environment variable |
| [docs/how-to/run-the-tests.md](docs/how-to/run-the-tests.md) | Running the suite safely |
| [TODO.md](TODO.md) | Known problems and what is left |

## Commands

```bash
just              # every recipe, grouped
just run          # API on :8080
just test         # serial, against the `test` database
just fmt          # swift-format; run before committing
just web          # dashboard dev server on :5174
just web-check    # svelte-check
just web-test     # vitest
just stack        # full local stack on Apple Container
```

## Setup that bites

- **`.env` must exist.** `configure` parses the Tapis settings, so without them every test fails in
  setup. Copy `.env.example`.
- **Set `DATABASE_TLS=disable` locally.** The default is `require`, and a local Postgres has no
  certificate.
- **Point local work at the staging tenant** (`https://icicleai.staging.tapis.io/v3`). Its vault is
  separate from production's. With a real token in `.env`, some vault tests write real secrets.
- **`TAPIS_BASE_URL` and `TAPIS_TENANT` must name the same tenant.** A mismatch boots cleanly, then
  refuses every administrator with a bare 403.
- **Tapis tokens are short-lived.** When every vault read fails at once, check `TAPIS_TOKEN` first.
  The boot log prints its expiry.
- **Set the environment with `VAPOR_ENV`, never `--env`.** A command-line flag outranks the variable,
  so one process ends up disagreeing with the others. The same goes for `--hostname` and `--port`.
- **Run `just dns` once per machine** before the first `just stack`, or containers cannot find each
  other.

## Conventions

- **`configure.swift` is the composition root.** It is the only place a concrete backend is chosen.
  Jobs and controllers depend on `SecretProvider` and `FailureNotifier`, never on `TapisClient`.
- **Comments explain why.** Existing comments record rejected alternatives and failures that cost real
  debugging. Keep them. Add rationale, not restatement.
- Every type and non-trivial function gets a doc comment: one summary line, then the reasoning.
- `swift-format` is authoritative. Run `just fmt` before committing.
- Errors that cross the API boundary conform to `AbortError`. Their reasons never contain credentials.
- `docker-compose.yml` and `justfiles/apple-container.just` describe the same stack with the same
  service names. Change one, change the other.

## Rules the code depends on

- **The scheduler runs as exactly one replica.** Two schedulers dispatch every due resource twice.
  Queue workers scale freely.
- **Jobs must be safe to retry.** Delivery is at least once. Collectors fetch first, then write
  everything in one transaction.
- **Failures re-book; they do not skip.** The sweep advances `nextCollectionAt` when it dispatches, as
  a lease. An exhausted failure must replace it with a capped backoff. Otherwise two failures push a
  GitHub resource past its 14-day traffic window and those days are lost.
- **A resource with no `nextCollectionAt` is never collected.** The sweep filters on `<= now`, which
  never matches NULL. Anything that creates resources must set a due date. npm and PyPI rows are
  left without one on purpose: their downloads cannot separate people from CI and caches, so they
  are not collected.
- **Watermarks stop double counting.** GitHub's traffic windows overlap between sweeps.
  `MetricWatermark.countedThrough` records which days are already in the all-time total.
- **Webhook signing keys live in their own `JWTKeyCollection`**, never in `app.jwt.keys`. JWTKit falls
  back to the default signer for an unknown `kid`. Tapis tokens carry a `kid` this server never
  registers, so a shared collection would check real admins against the wrong key.
- **Authenticators never reject.** Each logs in an identity or returns quietly. Only `Require`
  answers 401 or 403. That is what keeps public reads open.
- **`Require` is synchronous** and cannot query. Admin status is looked up during authentication and
  carried on `TapisUser.isAdmin`.
- **Secrets never reach logs or the database.** `Secret` redacts itself. `service_tokens` rows hold
  identifiers and metadata only.
- **`pg_dump` must be at least the database's major version.** The image installs
  `postgresql-client-18` from PostgreSQL's apt repository. Raise `PG_CLIENT_MAJOR` in the
  `Dockerfile` before, or with, a PostgreSQL upgrade, or every nightly backup fails.
- **Do not rename `withInsightsApp`.** `VaporTesting` has a generic `withApp` that wins overload
  resolution for single-expression closures and hands the test an empty app.

## Only a real boot catches these

The `.testing` environment skips the Tapis tenant key fetch and the vault keyset read. Changes on
those paths pass `just test` and can still fail at startup. Check them against staging.

## Documentation

**Ship docs with the change.** Reader-facing pages live under `docs/`, in one of four directories.
Plans and design notes are working files and can live elsewhere.

| Directory | Holds | Shape | Length |
|---|---|---|---|
| `tutorials/` | A guided path from start to finish | Narrative with checkpoints | 80–120 lines |
| `how-to/` | One task for someone who knows what they want | Numbered steps, verbs first | 30–60 lines |
| `reference/` | Facts to look up | Tables | As long as the tables need |
| `explanation/` | Why it is built this way | Prose with a subhead every ~10 lines | 60–100 lines |

- **One kind per page.** A how-to links to the explanation instead of arguing. Reference is tables.
- **Check every claim against the code or the running site**, never against another page.
- **Describe the UI as it is.** Open the screen and read its labels before writing about it.
- Open each page with one line saying what it is and who it is for.
- Keep sentences under about 25 words. Avoid chains of dashes and clauses.
- Code blocks are complete and copy-pasteable. At most one diagram per page.
- Add every new page to [docs/README.md](docs/README.md) in the same change.
- End each page with a tag line: `#icicle-insights#`, one kind tag, then one or more audience tags.

```
#icicle-insights# #How-To# #Administrator#
```

Kinds: `#Tutorial#`, `#How-To#`, `#Reference#`, `#Explanation#`. Audiences: `#Reader#` (anyone
viewing the dashboard), `#Administrator#` (runs the catalog or the deployment), `#Developer#`
(changes the code).

This repository is public. Use real usernames only where they already appear on the live site.

## Scope

This is built for ICICLE. `SecretProvider` and `FailureNotifier` are interfaces because each had a
real second implementation. Do not add abstraction for hypothetical deployments. Keep Tapis details
inside `Services/Tapis/` and the two authenticators.
