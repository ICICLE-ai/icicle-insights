# Deploy Insights

Stand up and operate a deployment. For administrators and developers.

One image, three processes, two backing services. The image is built from the repository root
`Dockerfile` and serves the API and the dashboard from the same container.

## Topology

| Process | Command | Replicas | Notes |
|---|---|---|---|
| API | `serve` | scale freely | The only one that takes traffic. Listens on 8080 |
| Worker | `queues --queue metrics` | scale freely | Does the collecting. Scale this when it falls behind |
| Scheduler | `queues --scheduled` | **exactly 1** | Hard constraint. Pin it; no autoscaler |

Plus PostgreSQL 18 and Valkey 9. Neither should be reachable from outside the cluster.

All three processes are required. Without the scheduler nothing is enqueued on a timer. Without the
worker, jobs accumulate in Valkey and no metric is ever written — silently, with a healthy API.

**Two schedulers dispatch every due resource twice.** There is no leader election. Set
`replicas: 1`, exclude it from any autoscaler, and prefer `Recreate` over `RollingUpdate` so two
never overlap during a deploy.

## Configuration

Five values have no default and the process exits at boot without them. All five are secrets —
mount them from your secret store, not from a manifest.

| Variable | Value |
|---|---|
| `TAPIS_BASE_URL` | Tenant base URL, **including `/v3`** |
| `TAPIS_TENANT` | Tenant ID. Must name the same tenant as the URL |
| `TAPIS_USER` | Service identity |
| `TAPIS_TOKEN` | Service token |
| `ROOT_ADMIN_USERNAME` | A real Tapis username in that tenant |

Then, on every process:

```dotenv
VAPOR_ENV=production
DATABASE_HOST=…
DATABASE_PASSWORD=…
REDIS_HOST=…
REDIS_PASSWORD=…
```

`SLACK_WEBHOOK_URL` belongs on the worker and scheduler only — jobs fail there, so that is where
alerts fire.

Full list in [Configuration](../reference/configuration.md).

Three mistakes account for most failed deployments:

- **`TAPIS_BASE_URL` and `TAPIS_TENANT` naming different tenants.** Each tenant has its own host.
  The pair boots cleanly and then refuses every administrator with a bare 403.
- **Omitting `/v3`.** Every Tapis URL is built off the base, so the tenant key fetch fails and the
  process exits.
- **A placeholder `ROOT_ADMIN_USERNAME`.** Boots fine, matches nobody, and every write returns 403.

Do not set `--env`, `--hostname`, or `--port` on a command line. Each outranks its environment
variable, which is how a stack ends up with processes disagreeing about their own configuration.
The image already defaults to production on 8080.

## Rollout order

Migrations are the coupling point. Everything else is independent.

1. **Migrate.** Run `migrate --yes` to completion as a one-shot job, before any process starts.
2. **Start the API and worker.** Both scale freely; roll them however you like.
3. **Start the scheduler**, at one replica.

Repeat step 1 on any deploy carrying a migration. The API's readiness probe fails until migrations
have run, because it queries a real table — so an un-migrated rollout stays out of the load balancer
rather than serving errors.

### First deployment only

```bash
Insights service-token init-key
```

Then restart the API.

Once per deployment, and staging and production are separate vaults — a keyset created against one
does not carry over. Until it exists, webhook authentication recognises nobody while administrator
access, public reads, and collection all work normally. It is logged at `critical` on every boot,
naming the command.

## Probes

| Probe | Endpoint | Checks | On failure |
|---|---|---|---|
| Liveness | `GET /health` | Process is up, nothing else | Restart |
| Readiness | `GET /ready` | PostgreSQL and Valkey both answer | Remove from the load balancer |

Both sit outside `/api`, so they are neither rate limited nor authenticated.

Liveness deliberately checks no dependencies. A brief database blip should not restart a server that
would have recovered.

Only the API serves HTTP. Give the worker and scheduler a process-level liveness check, not an HTTP
one.

## Verify

Every process should report the same environment:

```bash
for c in app queues scheduled; do docker compose logs $c | grep "Insights configured"; done
```

A correct boot prints these at `notice`:

```
HTTP middleware configured.        bind=… cors_origins=… frame_ancestors=… hsts=true
Secret provider selected.          provider=tapis tapis_base_url=… tapis_tenant=…
Root admin resolved.               username=…
Tapis tenant public key loaded; admin tokens verify locally.
Webhook token signing keys loaded. keys=N active_kid=…
Failure alerting configured.       channel=slack
Insights configured.               environment=production database=…
```

A missing line is a misconfiguration that surfaces days later as an unexplained 403 or a webhook
that quietly stopped working. Check this on every deploy; it is cheaper than the alternative.

## Rollback

The image is stateless — roll it back like anything else.

A migration is not. `migrate --revert --yes` rolls back the most recent batch, and is destructive
for whatever that batch added. Roll the image back first and confirm it runs against the newer
schema before reverting anything.

## Scaling

Scale the worker when collection falls behind:

```bash
docker compose up --scale queues=3 app queues scheduled
```

Two things bound how far that helps. Workers share the platform's rate allowance, so more of them
consume it faster — a 403 from GitHub calls for longer cadences, not more concurrency. And one queue
has head-of-line pressure, so slow jobs delay fast ones behind them.

Never scale the scheduler.

## Monitor

| Signal | Why |
|---|---|
| Scheduler heartbeat | A stopped scheduler is silent. Collection just stops |
| Queue depth on `metrics` | Sustained growth means workers cannot keep up |
| `critical` log lines | Credential failures and the missing-keyset warning are both critical |
| Provider rate limits | GitHub and Hugging Face both throttle |

The console's Operations screen surfaces the first three, including the scheduler heartbeat. See
[Admin console](../reference/admin-console.md).

## Networking

Publish the API only. Terminate TLS in front of it; the container serves plain HTTP on 8080.

Set `FRAME_ANCESTORS` if the dashboard will be embedded, and `CORS_ORIGINS` only if a browser origin
calls the API directly. Unset, framing is denied and no CORS middleware is installed at all — the
right posture for a same-origin deployment. See [Embed the dashboard](embed-the-dashboard.md).

## Then

- [Register an account](register-an-account.md) and add resources, or nothing is collected.
- [Diagnose a collection failure](diagnose-a-collection-failure.md) when something stops.

#icicle-insights# #How-To# #Administrator# #Developer# #deployment#
