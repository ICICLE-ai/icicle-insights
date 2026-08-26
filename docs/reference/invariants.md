# Invariants

Rules that must stay true. For developers.

These are correctness properties, not preferences. Breaking one needs a new design and new tests,
not a patch.

## Queues and scheduling

| Rule | Breaking it causes |
|---|---|
| Exactly one `queues --scheduled` replica | Every due resource dispatched twice |
| Every named queue has a running worker | Jobs pile up in Valkey, silently, forever |
| Jobs tolerate retries | Delivery is at-least-once; a retry corrupts or duplicates |
| Scheduled jobs only enqueue | A slow platform call delays the next tick |
| Sync jobs back off between attempts | An immediate requeue hammers a struggling API |
| `FailureNotifier.notify` never throws | The worker clears a job only after `error()` returns, so a failing alert channel strands the job |
| Every exhausted resource failure re-books its resource | The sweep's dispatch-time due date stands, so one failure costs a full cadence and gaps compound past the retention window |
| The failure backoff ceiling stays well inside `retentionWindowDays - maxCollectionIntervalDays` | The retry policy itself becomes the cause of a lost day |

Named workers may scale freely. Valkey claims each available payload atomically, so two workers
cannot take the same one.

## Metrics

| Rule | Breaking it causes |
|---|---|
| Fetch every provider response before writing a sweep | A partial snapshot: gauges stranded without the traffic rows sharing their timestamp |
| Fold rolling values through their watermark | Overlapping windows counted repeatedly |
| Fold only completed UTC days newer than the watermark | Today banked while still partial, then skipped once complete |
| Advance watermarks only through completed days | The same |
| Lock `(resource, metric type)` before a read-modify-write fold | Two workers corrupt one all-time value |
| Cadence stays at most half the platform's retention window | No headroom for a missed collection: one delayed sweep ages days out |
| A gap past the retention window raises `collection_window_exceeded`, once per outage | Data loss stays silent |

`Metric.foldDailyIntoAllTime` takes a transaction-scoped `pg_advisory_xact_lock`. FluentKit has no
row locking in this version. The hash uses PostgreSQL's `hashtext`, not Swift's `hashValue`, which
is seeded per process.

## Credentials

| Rule | Breaking it causes |
|---|---|
| Jobs and controllers reach credentials only through `SecretProvider` | A backend swap touches every consumer |
| `configure.swift` picks the concrete provider | The composition root stops being one |
| PostgreSQL stores references, never values | A database leak becomes a credential leak |
| `Secret` redaction survives into logs and errors | Credentials in log aggregation |

## Authentication

| Rule | Breaking it causes |
|---|---|
| Authenticators never reject | Public reads close |
| Only `Require` produces 401 and 403 | The same |
| Every mutating route carries a `Require` | An unguarded write |
| Admin status resolves during authentication | `Require`'s predicate is synchronous and cannot query |
| A token's `tapis/tenant_id` is compared against `TAPIS_TENANT` | A valid token from another tenant authenticates here |
| Webhook keys live in their own `JWTKeyCollection` | JWTKit falls back to the default signer for an unknown `kid`, so real administrators are verified against the HMAC key and rejected |
| Resource binding and expiry stay inside the signature | The holder widens their own scope |
| The `jti` resolves against a live row on every request, uncached | Revocation is delayed, which is the only thing the row exists for |
| `ROOT_ADMIN_USERNAME` cannot be removed through the API | An emptied table locks everyone out of the screen that manages it |
| An absent signing keyset is survivable; a refused read is not | Failing hard on absence takes down `service-token init-key`, the only thing that creates the keyset |

That last one is the bootstrap catch-22. Every command routes through `configure`, so a hard
failure on a missing keyset makes a fresh deployment impossible to set up. A 401, by contrast,
means the Tapis credentials are wrong and every collection job would fail silently, so it still
aborts the boot.

## Data and HTTP

| Rule | Breaking it causes |
|---|---|
| Tests use the `test` database | A stray run clobbers development or production |
| Seed data registers only in development | Fixture rows in a real deployment |
| DTOs are validated and normalised before becoming models | Invalid rows |
| Database TLS defaults secure | Plaintext connections by omission |
| Response-header middleware registers `at: .beginning` | Headers are applied on the way out, so anything later never sees an error response, and a 4xx without CORS headers is unreadable to the browser that caused it |
| Rate limiting fails open | A limiter that takes the API down with its counter store causes more harm than the abuse it prevents |

## Testing

`withInsightsApp` must keep its name. `VaporTesting` exports a generic `withApp` that boots a bare
application without `configure` — no routes, no database. For a single-expression closure the type
checker prefers that overload, silently handing the test an empty app, which surfaces as an
inexplicable 404. The distinct name removes the trap.

#icicle-insights# #Reference# #Developer# #correctness#
