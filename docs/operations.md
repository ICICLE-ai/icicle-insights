# Operations

Deploying, bootstrapping, and running Insights in production.

## Before the first deploy

Four things, in order. The third is the one people miss.

### 1. Environment

Required, and boot fails without them:

```dotenv
TAPIS_BASE_URL=https://icicleai.tapis.io/v3
TAPIS_TENANT=icicleai
TAPIS_USER=<service identity>
TAPIS_TOKEN=<service token>
ROOT_ADMIN_USERNAME=<a real tapis/username in the tenant above>
```

`TAPIS_BASE_URL` and `TAPIS_TENANT` name the **same** tenant, and each tenant has its own host.
The `/v3` suffix is required — every Tapis URL is built off the base, so omitting it fails the
tenant key fetch and the process exits.

```
production   icicleai   https://icicleai.tapis.io/v3
staging      icicleai   https://icicleai.staging.tapis.io/v3
```

Mismatching host and tenant is the expensive mistake: the tenant record still resolves, so the
service boots and looks healthy, and then `TapisAuthenticator` refuses every admin with a bare 403.
The boot log prints both values together for exactly this reason.

`ROOT_ADMIN_USERNAME` must be a real username in that tenant. A placeholder boots fine and matches
nobody.

### 2. Migrations

```bash
Insights migrate --yes
```

### 3. Signing keyset

```bash
Insights service-token init-key    # then restart
```

**Per deployment.** Staging and production are separate vaults; a keyset created against one does
not carry over.

Until it exists the service runs with an empty keyset: webhook authentication recognises nobody,
while admin access, public reads, and collection are unaffected. It is logged at `critical` on
every boot, naming the command. This is survivable by design — every command routes through
`configure`, so failing hard would take down `init-key` itself.

### 4. Verify the boot log

A correct start prints, at `notice`:

```
HTTP middleware configured.        cors_origins=… frame_ancestors=… hsts=true
Secret provider selected.          provider=tapis tapis_base_url=… tapis_tenant=…
Root admin resolved.               username=…
Tapis tenant public key loaded; admin tokens verify locally.
Webhook token signing keys loaded. keys=N active_kid=…
Failure alerting configured.       channel=slack
Insights configured.               environment=production database=…
```

Anything missing from that list is a misconfiguration that will otherwise surface days later as an
unexplained 403 or a webhook that silently stopped working.

## Health checks

| Endpoint | Meaning | On failure |
|---|---|---|
| `GET /health` | Process is up. Checks nothing else | Restart the pod |
| `GET /ready` | Postgres and Redis both answer | Remove from the load balancer |

Both sit outside `/api`, so probes are neither rate limited nor authenticated.

Liveness deliberately checks no dependencies: a brief database blip should not restart a server
that would have recovered. Readiness returns 503 when either backing service is unreachable — and
also before migrations have run, since it queries a real table.

## Processes

| Command | Role | Replicas |
|---|---|---|
| `serve` | HTTP API and dashboard | Scale horizontally |
| `queues --queue metrics` | Executes collection jobs | Scale horizontally |
| `queues --scheduled` | Evaluates clocks and dispatches | **Exactly one** |

Two schedulers enqueue the same work twice. This is the one hard scaling constraint.

## Rotating the signing keyset

```bash
Insights service-token rotate-key
```

Additive: the new key becomes active for minting while retired keys stay registered for
verification, so tokens issued beforehand keep working until they expire. No restart, no flag day.
Keys older than the longest possible token lifetime are dropped rather than accumulating.

Verify a rotation by minting, posting a metric, rotating, **restarting**, and posting again with
the original token. The restart is the part that matters — without it the old key is merely still
in memory, and nothing proves it was persisted.

## Webhook tokens

```bash
Insights service-token issue --resource <uuid> --label prod-inference
Insights service-token list
Insights service-token revoke --jti <uuid>
```

The token value is shown exactly once. Nothing persists it and no route reads it back; a lost token
is revoked and reissued. Minting for a resource that already has a live token revokes the old one
in the same transaction.

Tokens expire at 90 days. `WarnExpiringServiceTokens` sweeps daily at 07:00 and alerts at 14, 7,
3, and 1 days remaining — `warning` above three days, `critical` at or below. Fixed thresholds
rather than "anything under a fortnight", so a token does not alert every day for two weeks, which
is how a channel gets muted.

Alerts go wherever `FailureNotifier` points; with no Slack webhook configured they are log lines
at `warning`. `service-token list` shows expiry dates directly.

## Embedding the dashboard

`FRAME_ANCESTORS` is a comma-separated allowlist of origins permitted to iframe the dashboard.
Unset, responses carry `X-Frame-Options: DENY` and CSP `frame-ancestors 'none'`, and browsers
refuse the embed.

```dotenv
FRAME_ANCESTORS=https://tapisui.example.org
```

Origins only — scheme and host, no trailing path. Malformed entries are dropped with a warning
rather than passed through, because a policy the browser rejects wholesale fails *open* on framing.

Setting it omits `X-Frame-Options` entirely, since that header has no allowlist form and could then
only contradict the CSP.

## What to monitor

- **Scheduler liveness.** A stopped scheduler is silent — collection just stops.
- **Queue depth** on `metrics`. Sustained growth means workers cannot keep up.
- **`critical` log lines.** Credential failures and the missing-keyset warning are both critical.
- **Provider rate limits.** GitHub and Hugging Face both throttle.

Failures that exhaust their retries reach Slack when `SLACK_WEBHOOK_URL` is set; unset, they stay
in the log. `SLACK_WEBHOOK_URL_WARNINGS` optionally splits lower-severity failures into a second
channel so the primary stays quiet enough to act on.

## Request correlation

Every response carries `X-Request-ID`, and every log line for that request carries it as metadata.
An inbound `X-Request-ID` is honoured, so a caller can correlate across both sides; values that are
over-long or contain anything outside `[A-Za-z0-9_-]` are replaced, because the header reaches log
metadata verbatim.

## Continuous integration

`.github/workflows/build.yaml` runs `test` → `docker` → `release`. The test job brings up Postgres
and Valkey as services and runs the suite serially against them.

It sets `TAPIS_TOKEN` to a deliberate non-JWT placeholder. The vault tests that write real secrets
detect credentials by shape and skip themselves, because a real token would expire within hours and
turn the job red for reasons unrelated to the change under test.

## Known gaps

- **No CSP beyond `frame-ancestors`.** A full policy waits on the frontend's asset origins. The
  Leaf dashboard and the Scalar API reference both load scripts from jsdelivr, which a policy will
  need to allow or which should be vendored.

#icicle-insights# #operations# #deployment# #developer-documentation#
