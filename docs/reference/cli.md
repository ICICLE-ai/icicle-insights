# CLI

Every command the `Insights` binary accepts. For administrators and developers.

Run as `swift run Insights <command>` from a checkout, or `./Insights <command>` in the image.
`just token` and `just collect` wrap the two used most often.

Every command loads the full configuration first, so all commands need a valid environment. See
[Configuration](configuration.md).

## Long-running

| Command | Does | Replicas |
|---|---|---|
| `serve` | Serves the API and dashboard | Scale freely |
| `queues --queue metrics` | Executes collection jobs | Scale freely |
| `queues --scheduled` | Evaluates the clocks and dispatches | **Exactly one** |

Two schedulers dispatch every due resource twice. This is the one hard scaling limit.

`serve` takes no `--hostname`, `--port`, or `--env` flags. All three come from the environment so
that every process agrees.

## Migrations

| Command | Does |
|---|---|
| `migrate --yes` | Applies every pending migration |
| `migrate --revert --yes` | Rolls back the most recent batch |
| `migrate-locked` | The same, under a PostgreSQL advisory lock, without prompting |

Run `migrate` once before the first `serve`, and after any deploy carrying a migration.

`migrate-locked` is what the container entrypoint runs when the command is `serve`. The advisory
lock is session-scoped: extra API replicas starting together wait rather than race, and a migrator
that dies releases it when its connection closes. Use plain `migrate` for a deliberate deployment
step — see [Deploy Insights](../how-to/deploy-insights.md).

## Collection

| Command | Selects | Effect on schedule |
|---|---|---|
| `collect-resources` | Resources with `nextCollectionAt <= now` | Advances each dispatched resource by its cadence |
| `collect-resources --force` | Every active resource | Marks all due, dispatches, then advances each |
| `collect-accounts` | Every GitHub account | None; accounts carry no due date |
| `collect-patra-catalog` | Every Patra account | None; the catalog carries no due date |

All four only enqueue. A `queues --queue metrics` worker must be running or nothing is collected.
Watermarks still apply, so a forced run cannot double count. See
[Run collection immediately](../how-to/run-collection-immediately.md).

## Webhook tokens

`service-token` groups five subcommands.

| Command | Does |
|---|---|
| `service-token init-key` | Creates the signing keyset in the vault. Once per deployment |
| `service-token init-key --force` | Discards the existing keyset. **Invalidates every issued token** |
| `service-token rotate-key` | Adds a new active key, keeping old ones for verification |
| `service-token issue --resource <uuid> --label <text>` | Mints a token for one resource |
| `service-token issue … --expires-in-days <n>` | Sets the lifetime. 1–365, defaults to 90 |
| `service-token list` | Lists tokens with expiry and revocation state |
| `service-token revoke --jti <uuid>` | Revokes one token immediately |

`init-key` must run once per deployment, and restart afterwards. Staging and production are
separate vaults, so a keyset made against one does not carry over.

`issue` prints the token exactly once. Nothing stores it and no route reads it back. A lost token
is revoked and reissued. Minting for a resource that already holds a live token revokes the old one
in the same transaction.

`rotate-key` is additive and needs no restart. Tokens issued before a rotation keep working until
they expire. Use it in preference to `init-key --force`, which breaks every deployed service at
once.

## Health endpoints

Not commands, but the operational counterpart.

| Endpoint | Checks | On failure |
|---|---|---|
| `GET /health` | The process is up, nothing else | Restart the instance |
| `GET /ready` | PostgreSQL and Valkey both answer | Remove from the load balancer |

Liveness deliberately checks no dependencies, so a brief database blip does not restart a server
that would have recovered. Readiness also returns 503 before migrations have run, because it
queries a real table.

#icicle-insights# #Reference# #Administrator# #Developer# #cli#
