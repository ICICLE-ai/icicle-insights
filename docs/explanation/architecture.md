# Architecture

How Insights is put together: its processes, what happens to a request, and where the code lives.
For developers, and administrators who run a deployment.

## One image, three processes

Everything ships as one container image. The same binary runs in three roles, chosen by its
arguments:

```
            ┌────────────── PostgreSQL ──────────────┐
            │  accounts, resources, metrics, …       │
            └──────▲──────────────▲──────────────▲───┘
                   │              │              │
  browser ──► serve (API +    queues --queue    queues --scheduled
              dashboard)      metrics (worker)  (scheduler, 1 replica)
                   │              ▲  │              │
                   ▼              │  ▼              ▼
            ┌──────────────── Valkey ──────────────────┐
            │  job queue, rate-limit counters, locks   │
            └──────────────────────────────────────────┘
```

- **`serve`** answers HTTP. It serves the API, the OpenAPI document and the built dashboard. It runs
  no jobs.
- **`queues --queue metrics`** is the worker. It takes sync jobs off the queue, calls the platforms
  and writes readings. It can run as many copies as needed.
- **`queues --scheduled`** is the clock. On schedule it finds due work and queues it. It must run
  as exactly one copy, or every resource is queued twice.

Splitting them means a slow platform never delays a web request, and a restart of the API never
drops scheduled work. Jobs wait in Valkey until a worker is free.

## Backing services

PostgreSQL holds everything the dashboard shows. Valkey, or any Redis-protocol server, holds the job
queue, the rate-limit counters, the scheduler's heartbeat and the alert deduplication keys. Losing
Valkey loses queued jobs, not collected data. A resource whose job was lost waits for its next due
date, because the sweep books that date when it queues the job.

Credentials live in neither. Platform tokens and the service-token signing keys are stored in
Tapis Vault and read when needed.

## Backups

When `BACKUP_S3_BUCKET` is set, the scheduler queues a backup at 02:00 UTC. A worker runs `pg_dump`
and uploads the archive to S3-compatible storage in one signed request. It runs inside the app
rather than in a backup container of its own. Tapis Pods offers no cron we know of, a separate pod
is one more thing to deploy, and this way a failure alerts like a failed collection. The bucket's
lifecycle rule deletes old backups, so the deployment's key only ever needs to write.

## What a request goes through

Every response gets a request ID, security headers and, when configured, CORS headers. Static
dashboard files are served straight from `Public/`. Hashed assets are cached for a year, and the
entry page is revalidated on every visit.

Requests under `/api` then pass, in order:

1. **A rate limiter** per client address, 300 a minute by default, counted in Valkey so the limit
   holds across API replicas.
2. **Two authenticators.** One recognises Tapis user tokens. The other recognises service tokens.
   Neither rejects anything, so anonymous reads work.
3. **The route's own requirement.** Writes demand an administrator. The service metrics route
   accepts an administrator or the one service its token names. This is the only place a 401 or 403
   comes from.

Any other path that is not a file gets the dashboard's `index.html`, so links such as
`/resources/{id}` work on reload. Unknown `/api` paths still answer a JSON 404.

## Startup

Each process reads its configuration, checks the Tapis settings, fetches the tenant's public key and
loads the service-token keyset from Vault. The `serve` process applies database migrations first,
under a PostgreSQL lock, so several replicas can start together. A missing required variable stops
the process at boot rather than half-starting it.

## Source layout

| Path | Holds |
|---|---|
| `Sources/Insights/configure.swift` | Wiring: database, queues, secrets, schedules, commands |
| `Sources/Insights/routes.swift` | Route groups and middleware order |
| `Controllers/` | HTTP routes, including the SQL summaries in `InsightsQueries.swift` |
| `Middlewares/` | Authentication, requirements, rate limiting, headers |
| `Models/`, `Migrations/`, `DTOs/` | Database models, schema changes, request and response shapes |
| `Queues/Collectors/` | One sync job per platform |
| `Queues/Scheduled/` | The scheduler's jobs |
| `Queues/Backups/` | The database backup job |
| `Queues/Support/` | Retry, backoff, failure reporting, alert deduplication |
| `Services/` | Tapis, secrets, notifications, service tokens, Patra and GHCR parsing, backups |
| `Commands/` | Command-line tools |
| `web/` | The SvelteKit dashboard |
| `Tests/InsightsTests/` | The server test suite |

#icicle-insights# #Explanation# #Developer# #Administrator#
