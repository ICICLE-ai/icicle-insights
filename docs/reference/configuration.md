# Configuration

Every environment variable Insights reads, for administrators running a deployment and developers
running it locally. `.env.example` is a commented starting point.

All three processes read the same variables. Set them the same way everywhere.

## Required

A missing value stops the process at startup.

| Variable | Meaning |
|---|---|
| `TAPIS_BASE_URL` | The tenant's Tapis API, ending in `/v3`. Production `https://icicleai.tapis.io/v3`; staging `https://icicleai.staging.tapis.io/v3` |
| `TAPIS_TENANT` | The tenant id, `icicleai`. Must match the host in `TAPIS_BASE_URL` |
| `TAPIS_TOKEN` | The service user's Tapis token, for Tapis Vault. Short-lived; see [Renew the Tapis service token](../how-to/renew-the-tapis-token.md) |
| `TAPIS_USER` | The service user. Vault secrets live under this user's path |
| `ROOT_ADMIN_USERNAME` | The Tapis username that is always an administrator |

A mismatched `TAPIS_BASE_URL` and `TAPIS_TENANT` starts cleanly, then refuses every administrator
with 403. A wrong `TAPIS_USER` shows up as *secret not found*.

## Runtime

| Variable | Default | Meaning |
|---|---|---|
| `VAPOR_ENV` | `development`; the image sets `production` | Environment. Also picks the default database name and whether seed data is added |
| `LOG_LEVEL` | `info`; `notice` in production | `trace`, `debug`, `info`, `notice`, `warning`, `error` or `critical` |
| `SERVER_HOSTNAME` | `0.0.0.0` | Interface the API listens on |
| `SERVER_PORT` | `8080` | Port the API listens on |
| `SECRET_PROVIDER` | `tapis` | Where credentials are stored. `tapis` is the only value |

Never pass `--env`, `--hostname` or `--port` on the command line. A flag overrides the variable for
one process only, and the processes then disagree.

## PostgreSQL

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_HOST` | `localhost` | Host |
| `DATABASE_PORT` | `5432` | Port |
| `DATABASE_NAME` | `dev` in development, `vapor_database` in production | Database. Tests always use `test` |
| `DATABASE_USERNAME` | `vapor_username` | User |
| `DATABASE_PASSWORD` | `vapor_password` | Password |
| `DATABASE_TLS` | TLS required | Set `disable` for a local database without TLS. The certificate is not verified |

## Valkey

| Variable | Default | Meaning |
|---|---|---|
| `REDIS_HOST` | `localhost` | Host of Valkey or any Redis-protocol server |
| `REDIS_PORT` | `6379` | Port |
| `REDIS_PASSWORD` | none | Password. Empty means no authentication |

## HTTP

| Variable | Default | Meaning |
|---|---|---|
| `CORS_ORIGINS` | unset, no CORS | Comma-separated browser origins allowed to call the API from another site |
| `FRAME_ANCESTORS` | unset, framing denied | Comma-separated origins allowed to frame the dashboard, such as `https://icicleai.tapis.io` |
| `RATE_LIMIT_PER_MINUTE` | `300` | Requests per minute per client address on `/api` |
| `WEBHOOK_RATE_LIMIT_PER_MINUTE` | `60` | Requests per minute per service token on the service metrics route |

## Tokens and alerts

| Variable | Default | Meaning |
|---|---|---|
| `TOKEN_SIGNING_SECRET` | `insights-token-signing-key` | Name of the Vault secret holding the service-token signing keys |
| `SLACK_WEBHOOK_URL` | unset, log only | Slack incoming webhook for alerts |
| `SLACK_WEBHOOK_URL_WARNINGS` | `SLACK_WEBHOOK_URL` | Separate webhook for warnings, keeping the main channel for credential failures |

Alerts are sent by the worker and the scheduler. Setting the webhooks on the API has no effect.

## Database backups

Backups are off until `BACKUP_S3_BUCKET` is set. Then the four marked *required* must be set too,
or the process stops at startup. An empty value counts as unset.

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_S3_BUCKET` | unset, backups off | Bucket to upload to |
| `BACKUP_S3_ENDPOINT` | required | The store's API as `http(s)://host[:port]`, with no path. AWS: `https://s3.us-east-2.amazonaws.com` |
| `BACKUP_S3_REGION` | required | Region named in the request signature, such as `us-east-2`. Self-hosted stores usually default to `us-east-1` |
| `BACKUP_S3_ACCESS_KEY_ID` | required | Access key. Needs only `s3:PutObject` under the prefix |
| `BACKUP_S3_SECRET_ACCESS_KEY` | required | Its secret. Never logged |
| `BACKUP_S3_PREFIX` | `insights/` | Start of every object key. A leading `/` is dropped and a trailing `/` added |
| `BACKUP_S3_PATH_STYLE` | `true` | `true` sends `endpoint/bucket/key`; `false` sends `bucket.endpoint/key`. Self-hosted stores usually need `true` |
| `BACKUP_S3_SSE` | `true` | Sends `x-amz-server-side-encryption: AES256`. Set `false` for a store that refuses the header |

`true` and `false` also accept `1`, `0`, `yes` and `no`. Any other value stops the process at
startup.

Set these on the worker and the scheduler. The scheduler decides whether to queue a backup, and the
worker takes it. The API checks them at startup but never runs a backup. Keys look like
`insights/vapor_database/2026/09/vapor_database-20260924T020000Z.dump`.

## Build time

| Variable | Where | Default | Meaning |
|---|---|---|---|
| `VITE_TRUSTED_PARENT_ORIGINS` | Docker build argument | `https://icicleai.tapis.io` | Parent frames allowed to hand the dashboard a token |
| `INSIGHTS_API` | `just web` | `http://127.0.0.1:8080` | Where the dashboard dev server forwards `/api` |

## Local stack only

Read by `justfiles/apple-container.just`.

| Variable | Default | Meaning |
|---|---|---|
| `APP_PORT` | `80` | Port inside the app container |
| `APP_HOST_PORT` | `8080` | Port on `127.0.0.1` |
| `CONTAINER_BUILD_DNS`, `CONTAINER_BUILD_DNS_ALT` | `75.75.75.75`, `75.75.76.76` | Resolvers used while building the image |

#icicle-insights# #Reference# #Administrator# #Developer#
