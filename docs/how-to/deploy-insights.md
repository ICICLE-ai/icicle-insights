# Deploy Insights

Stand up a new deployment. For administrators.

Four steps in order. The third is the one people miss.

## 1. Set the environment

Five variables have no default and boot fails without them.

```dotenv
VAPOR_ENV=production
TAPIS_BASE_URL=https://icicleai.tapis.io/v3
TAPIS_TENANT=icicleai
TAPIS_USER=<service identity>
TAPIS_TOKEN=<service token>
ROOT_ADMIN_USERNAME=<a real tapis username in that tenant>
```

Three things to get right:

- **`TAPIS_BASE_URL` and `TAPIS_TENANT` must name the same tenant.** Each tenant has its own host.
  A mismatch boots cleanly and then refuses every administrator with a bare 403.
- **The `/v3` suffix is required.** Every Tapis URL is built off the base, so omitting it fails the
  tenant key fetch and the process exits.
- **`ROOT_ADMIN_USERNAME` must be a real username.** A placeholder boots fine and matches nobody.

Set `VAPOR_ENV` as a variable on every process. Never pass `--env` on a command line: it outranks
the variable, which is how a stack ends up with processes disagreeing about their own environment.

Full list in [Configuration](../reference/configuration.md).

## 2. Run migrations

```bash
docker compose run --rm migrate
```

Repeat after any deploy carrying a migration.

## 3. Create the signing keyset

```bash
Insights service-token init-key
```

Then **restart**.

**Once per deployment.** Staging and production are separate vaults; a keyset created against one
does not carry over.

Until it exists, the service runs with an empty keyset. Webhook authentication recognises nobody,
while administrator access, public reads, and collection all work normally. It is logged at
`critical` on every boot, naming the command.

## 4. Verify the boot log

Every process should report the same environment.

```bash
for c in app queues scheduled; do docker compose logs $c | grep "Insights configured"; done
```

A correct start prints these at `notice`:

```
HTTP middleware configured.        bind=… cors_origins=… frame_ancestors=… hsts=true
Secret provider selected.          provider=tapis tapis_base_url=… tapis_tenant=…
Root admin resolved.               username=…
Tapis tenant public key loaded; admin tokens verify locally.
Webhook token signing keys loaded. keys=N active_kid=…
Failure alerting configured.       channel=slack
Insights configured.               environment=production database=…
```

Anything missing is a misconfiguration that will otherwise surface days later as an unexplained 403
or a webhook that silently stopped working.

## Run the three processes

| Process | Command | Replicas |
|---|---|---|
| API and dashboard | `serve` | Scale freely |
| Queue worker | `queues --queue metrics` | Scale freely |
| Scheduler | `queues --scheduled` | **Exactly one** |

All three are needed. Without the scheduler nothing is enqueued on a timer. Without the worker,
jobs pile up in Valkey and no metric is ever written, silently.

```bash
docker compose up app queues scheduled
```

Scale the worker when collection falls behind:

```bash
docker compose up --scale queues=3 app queues scheduled
```

Never scale the scheduler. Two dispatch every due resource twice.

## Wire up the platform

| Setting | Value |
|---|---|
| Liveness probe | `GET /health` |
| Readiness probe | `GET /ready` |
| Restart policy | `unless-stopped` on the three long-lived services |
| Published ports | The API only. Keep the database and queue private |
| TLS | Terminate in front of the service |

Readiness returns 503 before migrations have run, because it queries a real table.

## Deployment differences from local

| Setting | Local | Deployment |
|---|---|---|
| `VAPOR_ENV` | `development` | `production` |
| `DATABASE_TLS` | `disable` | required |
| `DATABASE_PASSWORD` | the default | replaced |
| `REDIS_PASSWORD` | empty | set, with Valkey started `--requirepass` |

`VAPOR_ENV=production` also selects the production database name and keeps the development seed
migration from running against real data.

## Then

- [Register an account](register-an-account.md) and add resources.
- Set `FRAME_ANCESTORS` if the dashboard will be embedded — see
  [Embed the dashboard](embed-the-dashboard.md).
- Set `SLACK_WEBHOOK_URL` on `queues` and `scheduled` so failures reach a person.

## What to monitor

- **Scheduler liveness.** A stopped scheduler is silent; collection just stops.
- **Queue depth** on `metrics`. Sustained growth means workers cannot keep up.
- **`critical` log lines.** Credential failures and the missing-keyset warning are both critical.
- **Provider rate limits.** GitHub and Hugging Face both throttle.

#icicle-insights# #How-To# #Administrator# #deployment#
