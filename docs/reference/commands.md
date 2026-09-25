# Commands

The binary's commands and the `just` recipes that wrap them, for developers and administrators. In
a container the binary is `./Insights`. From the repository it is `swift run Insights`.

## Processes

| Command | Runs |
|---|---|
| `serve` | The API and dashboard. The container migrates the database first |
| `queues --queue metrics` | The worker that runs sync jobs |
| `queues --scheduled` | The scheduler. Exactly one copy |

## One-shot commands

| Command | Does |
|---|---|
| `migrate --yes` | Apply pending migrations |
| `migrate --revert --yes` | Roll back the most recent batch |
| `migrate-locked` | Apply migrations under a PostgreSQL advisory lock; safe from several replicas |
| `collect-resources` | Queue every resource that is due now |
| `collect-resources --force` | Mark every active resource due, then queue them. Shifts every schedule |
| `collect-accounts` | Queue a follower sync for every GitHub account |
| `collect-patra-catalog` | Queue Patra catalog discovery |
| `backup-database` | Dump the database and upload it to the backup bucket now, and wait. Exits non-zero when backups are off or the backup fails |
| `service-token init-key` | Create the signing keyset in Tapis Vault. Refuses if one exists |
| `service-token init-key --force` | Replace the keyset. Every issued token stops working |
| `service-token rotate-key` | Add a new signing key; old tokens keep working. Restart the API afterwards |
| `service-token issue --resource <uuid> --label <name> [--expires-in-days <n>]` | Issue a token, printed once. Default 90 days |
| `service-token revoke --jti <uuid>` | Revoke a token |
| `service-token list` | List issued tokens, without values |

The collect commands only queue work; a worker must be running. `backup-database` does the work
itself and sends no alert, so run it where the worker's environment is set.

## `just` recipes

Run `just` with no arguments to list them. They load `.env` automatically.

### Server

| Recipe | Runs |
|---|---|
| `just run` | `swift run Insights serve` |
| `just migrate` | `migrate --yes` |
| `just revert` | `migrate --revert --yes` |
| `just test` | `swift test --no-parallel` |
| `just fmt` | Format `Sources`, `Tests` and `Package.swift` |
| `just fmt-check` | Report formatting problems |
| `just token …` | `service-token …` |
| `just collect …` | `collect-resources …` |
| `just collect-accounts` | `collect-accounts` |
| `just collect-patra-catalog` | `collect-patra-catalog` |

### Dashboard

| Recipe | Runs |
|---|---|
| `just web-install` | `deno install --frozen` in `web/` |
| `just web` | Dev server on port 5174 |
| `just web-check` | Type checks |
| `just web-test` | Unit tests |
| `just web-build` | Static build into `web/build` |
| `just web-types` | Regenerate `web/src/lib/api/schema.d.ts` from the running API |

### Local stack on Apple Container

| Recipe | Does |
|---|---|
| `just dns` | Register the `icicle-insights` DNS domain. Once per machine; asks for a password |
| `just dns-delete` | Unregister it |
| `just stack` | Rebuild and restart everything: database, Valkey, migrations, app, worker, scheduler |
| `just stop` | Stop and remove the containers; data survives |
| `just clean` | `stop`, and remove the network |
| `just destroy` | Delete containers, volumes, image and builder. Asks you to type `destroy` |
| `just build` | Build the image |
| `just db`, `just valkey` | Start one backing service |
| `just app`, `just queues`, `just scheduled` | Start one process |
| `just stack-migrate`, `just stack-revert` | Migrate inside the stack |
| `just stack-test` | Run the server tests inside the stack's network |
| `just collect-now`, `just collect-all-now` | Sweep due resources, or all of them |
| `just collect-accounts-now`, `just collect-patra-catalog-now` | The other sweeps |

The app is reachable at <http://app.icicle-insights> and <http://127.0.0.1:8080>.

### Docker Compose equivalents

| Command | Does |
|---|---|
| `docker compose up app queues scheduled` | Run the stack |
| `docker compose run --rm migrate` | Migrate |
| `docker compose run --rm collect-now` | Sweep due resources |
| `docker compose run --rm collect-all-now` | Sweep every resource |
| `docker compose run --rm collect-accounts-now` | Account sweep |
| `docker compose run --rm collect-patra-catalog-now` | Patra sweep |
| `docker compose run --rm queues backup-database` | Back up now, with the worker's settings |

#icicle-insights# #Reference# #Developer# #Administrator#
