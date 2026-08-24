# Configuration

Every environment variable Insights reads. For administrators.

All values are read at boot by `configure.swift`. A change needs a restart.

## Required

Boot fails if any of these is missing.

| Variable | Value |
|---|---|
| `TAPIS_BASE_URL` | Tenant base URL, including the `/v3` suffix |
| `TAPIS_TENANT` | Tenant ID. Must name the same tenant as the URL above |
| `TAPIS_USER` | Service username. Scopes the vault path |
| `TAPIS_TOKEN` | Service access token. Secret; short-lived |
| `ROOT_ADMIN_USERNAME` | A real `tapis/username` in that tenant |

`TAPIS_BASE_URL` and `TAPIS_TENANT` move together. Each tenant has its own host.

| Environment | `TAPIS_TENANT` | `TAPIS_BASE_URL` |
|---|---|---|
| Production | `icicleai` | `https://icicleai.tapis.io/v3` |
| Staging | `icicleai` | `https://icicleai.staging.tapis.io/v3` |

A mismatched pair boots cleanly and then refuses every administrator with a bare 403.
The boot log prints both together so the mismatch is visible on startup.

## Runtime

| Variable | Default | Notes |
|---|---|---|
| `VAPOR_ENV` | `development` | Set `production` in a deployment. Read by every process |
| `LOG_LEVEL` | `debug` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |
| `SECRET_PROVIDER` | `tapis` | Any other value fails at boot |

Never pass `--env` on a command line. It outranks `VAPOR_ENV`, which is how a stack ends up with
processes disagreeing about their own environment.

`VAPOR_ENV` also selects the database name and gates the development seed migration. See
[Data model](data-model.md).

## HTTP server

Read by `serve` only.

| Variable | Default | Notes |
|---|---|---|
| `SERVER_HOSTNAME` | `0.0.0.0` | Which interfaces to accept on. Vapor's own default of `127.0.0.1` leaves a container unreachable |
| `SERVER_PORT` | `8080` | |
| `CORS_ORIGINS` | unset | Comma-separated. Unset installs no CORS middleware at all |
| `FRAME_ANCESTORS` | unset | Comma-separated origins allowed to iframe the dashboard. Unset denies framing |
| `RATE_LIMIT_PER_MINUTE` | `300` | Per client address, across `/api` |
| `WEBHOOK_RATE_LIMIT_PER_MINUTE` | `60` | Per token, on the metric-reporting route |

HSTS is sent when `VAPOR_ENV=production`, and not otherwise.

## PostgreSQL

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_HOST` | `localhost` | |
| `DATABASE_PORT` | `5432` | |
| `DATABASE_NAME` | see below | |
| `DATABASE_USERNAME` | `vapor_username` | |
| `DATABASE_PASSWORD` | `vapor_password` | Replace in a deployment |
| `DATABASE_TLS` | TLS required | Set `disable` only for the local stock container, which serves no TLS |

`DATABASE_NAME` defaults by environment: `test` under testing, `dev` under development,
`vapor_database` otherwise. Under TLS the certificate is encrypted but not verified, matching
libpq's `sslmode=require`.

## Valkey

Used for both queue storage and rate-limit counters.

| Variable | Default | Notes |
|---|---|---|
| `REDIS_HOST` | `localhost` | |
| `REDIS_PORT` | `6379` | |
| `REDIS_PASSWORD` | empty | Empty means no authentication. Set it and start Valkey with `--requirepass` to match |

## Credentials and alerting

| Variable | Default | Notes |
|---|---|---|
| `TOKEN_SIGNING_SECRET` | `insights-token-signing-key` | Name of the vault secret holding the webhook keyset |
| `SLACK_WEBHOOK_URL` | unset | Collection failure alerts. Unset logs only |
| `SLACK_WEBHOOK_URL_WARNINGS` | unset | Optional second channel for lower-severity failures |

Set the Slack variables on the `queues` and `scheduled` processes. Jobs fail there, so that is
where the notifier fires.

## Verifying a boot

Every process should print the same environment. A correct start logs these at `notice`:

```
HTTP middleware configured.        bind=… cors_origins=… frame_ancestors=… hsts=true
Secret provider selected.          provider=tapis tapis_base_url=… tapis_tenant=…
Root admin resolved.               username=…
Tapis tenant public key loaded; admin tokens verify locally.
Webhook token signing keys loaded. keys=N active_kid=…
Failure alerting configured.       channel=slack
Insights configured.               environment=production database=…
```

A missing line is a misconfiguration. See [Deploy Insights](../how-to/deploy-insights.md).

#icicle-insights# #Reference# #Administrator# #configuration#
