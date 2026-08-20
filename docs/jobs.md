# Adding a job

How a job gets from a file to a worker actually running it. Companion to
[collection.md](collection.md), which covers *why* the metrics are shaped the way they are.

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
flowchart LR
    A[AsyncScheduledJob] -->|dispatch payload| B[(Named Valkey queue)]
    C[HTTP route or another job] -->|dispatch payload| B
    B --> D[queues --queue name]
    D --> E[Registered AsyncJob handler]
    E --> F[Platform API and PostgreSQL]
```

## The three files

Adding a platform sync connects three files. Registration gives workers a decoder and handler;
routing places the typed payload on the correct queue.

| # | File | What it does |
|---|---|---|
| 1 | `Sources/Insights/Queues/SyncXStats.swift` | The work itself |
| 2 | `Sources/Insights/configure.swift` | `app.queues.add(...)` — maps the job's name to a decoder |
| 3 | `Sources/Insights/Queues/Queue+SyncDispatch.swift` | Routes a platform to the job |

**Controllers need no change.** `ResourceController.create` and `CollectDueResources` both call
`dispatchSync(for:platform:logger:)`, so wiring the platform in step 3 gets you create-time
collection and the hourly sweep at once. That is the reason the routing lives in one extension
rather than at each call site.

### 1. The job

```swift
import Fluent
import Foundation
import Queues
import Vapor

/// Payloads are values on a queue, not references — only the id crosses. The job re-reads the
/// row, so a resource edited between dispatch and dequeue is synced as it is now.
struct GHCRResource: Codable {
  let id: UUID
}

struct SyncGHCRStats: AsyncJob, BackoffRetrying {
  typealias Payload = GHCRResource
  let baseUrl = "https://github.com/orgs"

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: GHCRResource) async throws {
    await context.reportResourceSyncFailure(error, job: Self.name, resourceID: payload.id)
  }

  func dequeue(_ context: QueueContext, _ payload: GHCRResource) async throws {
    guard
      let resource = try await Resource.query(on: context.application.db)
        .filter(\.$id == payload.id)
        .with(\.$account)
        .first()
    else {
      // Not a throw. A deleted row will not reappear, and `QueueWorker` decides whether to retry
      // from the remaining attempt count alone — so throwing here costs four attempts across ten
      // minutes to rediscover that it is gone. Returning completes the job on the first one.
      context.entryVanished(id: payload.id, job: Self.name)
      return
    }

    // fetch, then write
  }
}
```

Conventions the existing jobs follow:

- **Fetch everything, then write.** `SyncGitHubRepoStats` collects all three responses before
  creating a single `Metric` batch, so a failure partway through leaves no half-swept resource —
  gauges stranded without the traffic rows that share their timestamp. There's a test for this.
- **A missing subject is not a failure.** If the row the job was dispatched for has been deleted,
  call `context.entryVanished(id:job:)` and return. Retries cannot help — the row is gone — and the
  worker has no way to be told not to retry once something throws.
- **Express real failures as `JobError`.** The three cases in `Sources/Insights/Errors/JobError.swift`
  (`missingToken`, `apiRequestFailed`, `decodingFailed`) are what the tests
  pattern-match on, and its `DebuggableError` conformance is what decides the log severity and
  whether anyone is alerted. Throwing anything else still works, but it is reported as an
  unclassified `.warning` with no suggested fix.
- **Conform to `BackoffRetrying` and implement `error(_:_:_:)`.** Both are one line each and are
  covered under [Failure handling](#failure-handling) below.
- **Token, if the API needs one.** Look up the account's `Vault`, then
  `context.application.secrets.readSecret(named:)`. The selected `SecretProvider` resolves it.
  Public endpoints, such as GHCR package pages, can omit credential lookup and the associated
  `missingToken` failure mode.

### 2. Register the handler — `configure.swift`

```swift
let syncGHCRStats = SyncGHCRStats()
app.queues.add(syncGHCRStats)
```

`add` is what lets a worker turn a queued id back into a typed payload and a handler. Without
it the dispatch still succeeds — the failure surfaces on the *worker*, at dequeue time, as an
unknown job name.

### 3. Route the platform — `Queue+SyncDispatch.swift`

```swift
case .ghcr:
  try await dispatch(SyncGHCRStats.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
case .npm, .pypi:
  logger.debug("No sync job for platform; skipping resource", metadata: [...])
```

`maxRetryCount` is not optional in practice: it defaults to `0`, and a job dispatched without it
gives up on the first transient 503.

Platforms without a job are listed in the skip branch rather than throwing: they are
legitimately in the catalog, just not collectable. The `switch` is exhaustive over `Platform`,
so adding a platform forces you to decide which branch it belongs in.

## Failure handling

A sync job fails for two unrelated reasons, and they need opposite responses: a throttled API
wants another attempt in a minute, an expired token wants a person. The split is driven entirely
by which `JobError` case is thrown.

### The retry ladder

Dispatch sites pass `maxRetryCount: syncJobMaxRetryCount` (3). Conforming to `BackoffRetrying`
replaces `Job`'s default `nextRetryIn` — which returns `0`, requeueing *immediately*, so three
attempts against a rate-limited API land inside the same second — with **30s, 2m, 8m**. The whole
budget finishes inside the hourly sweep interval, so a resource is never retrying and being
re-dispatched at the same time.

Retries are error-blind: `nextRetryIn(attempt:)` receives the attempt number and nothing else, so
a dead token spends all three attempts before anyone is told. That costs three wasted API calls
per sweep and buys a much simpler design; revisit only if it shows up as rate-limit pressure.

### Classification

`JobError`'s `DebuggableError` conformance gives the log its severity, `identifier`, and
explanation. The one question that changes the response — is a person needed? — is answered by the
failure handler itself, in a private `Error` extension in `SyncJob+Failure.swift`.

| Error | Log level | Alert | Re-books the resource |
|---|---|---|---|
| `JobError.missingToken`, `apiRequestFailed` 401/403 | `.critical` | 🔴 credential | yes — ~1 hour |
| `TapisClientError.secretNotFound`, `requestFailed` 401/403 | `.critical` | 🔴 credential | yes — ~1 hour |
| `JobError.apiRequestFailed`, other statuses | `.warning` | ⚠️ | no |
| `JobError.decodingFailed` | `.error` | ⚠️ | no |
| Subject deleted (`entryVanished`) | `.notice` | none | no — the job completes |
| `TapisClientError.invalidResponse`, 5xx | `.warning` | ⚠️ | no |
| Anything else | `.warning` | ⚠️ `unknown` | no |

`TapisClientError` belongs in that table as much as `JobError` does, and it is easy to miss: a
job's token comes from the *vault*, not the platform, so an expired `TAPIS_TOKEN` or a missing
secret breaks collection for every account at once while the platform APIs are perfectly healthy.
Classifying only `JobError` would have given that failure an anonymous warning and left the
resource on its weekly cadence.

That classification lives in the queue, not on `TapisClientError`. What a vault failure means to a
*job* — collection is stopped until someone acts — is the queue's concern; the Tapis adapter's
`AbortError` conformance already says what the HTTP boundary needs, and the service type stays
free of queue semantics. The one cost is that the failure handler names the cases explicitly, so a
third credential source is a case to add there.

Because `TapisClientError` reports `.warning` through `AbortError`, the handler logs credential
failures at `.critical` itself rather than deferring to the error's own level.

Without the `DebuggableError` conformance `Logger.report(error:)` falls to its `default` branch
and logs `String(reflecting:)` at `.warning` — a reflected enum dump, with a dead credential at
the same severity as a transient blip.

### What `error(_:_:_:)` does

It runs **once the retry budget is spent**, never before, and delegates to one shared helper in
`Sources/Insights/Queues/SyncJob+Failure.swift`:

1. Logs through `report(error:)` with filterable metadata — `job`, `subject`, `identifier`,
   `platform`, and the resource or account id.
2. Sends a `FailureAlert` to `app.notifier`.
3. On a credential failure only, re-books `nextCollectionAt` about an hour out.

Step 3 is the one worth understanding. `CollectDueResources` advances the due date when it
*dispatches*, not when the job succeeds, so a job that fails afterwards would otherwise sit out a
full `collectionIntervalDays` — a week by default. Re-booking keeps it in the hourly rotation, so
a token repaired at any point is picked up within the hour rather than the following week.

`SyncGitHubOrgStats` has no counterpart: `Account` carries no due date, since `CollectAccountStats`
is fixed-monthly. A credential failure there alerts and then waits for that schedule, or for an
operator to run `just collect-accounts-now`.

### Alerting

`app.notifier` is a `FailureNotifier`, selected in `configure.swift` the same way `app.secrets`
is. `SLACK_WEBHOOK_URL` unset yields `NoopNotifier` and failures stay in the log — the right
setting for tests and local runs.

Set `SLACK_WEBHOOK_URL_WARNINGS` to route ⚠️ failures to a second channel; unset, everything goes
to the one webhook tagged by severity.

`FailureNotifier.notify` is `async` but deliberately **not** `throws`. `QueueWorker.runOneJob`
awaits `job._error(...)` *before* clearing the job, so an alert channel that threw would strand
the job and stop the worker's run loop. A channel that cannot be reached degrades to a log line.

## Choosing the all-time handling

This is the decision that gets metrics wrong if rushed. Match the API's shape to a helper:

| The API reports | Store as | All-time helper |
|---|---|---|
| Current value (stars, forks, likes) | `.stars` etc. | **none** — `MetricType.allTime` is nil, the series *is* the record |
| Overlapping window **with a per-day array** (GitHub traffic) | the window count | `Metric.foldDailyIntoAllTime` |
| Overlapping window, no per-day array, but a lifetime total alongside (the Hub) | the window count | `Metric.setAllTime` with the reported total |
| A lifetime total only (likely GHCR pulls) | `.pullsAllTime` directly | **none** — it is already the total |

`Metric.addToAllTime` accumulates and is only safe for genuine deltas. No current job calls it
directly; `foldDailyIntoAllTime` uses it internally once it has filtered the days down to ones
never counted before. Feeding it a rolling window is the bug
[collection.md](collection.md#why-rolling-windows-need-special-handling) explains the failure
mode in detail.

## Adding a new platform, metric type, or resource type

All three are Postgres enums, created in `FirstMigration`. Adding a Swift case is not enough —
an insert with an unknown value fails at the database. You need a new additive migration:

```swift
try await database.enum("metric_type").case("newThing").update()
```

Then register it in `configure.swift` **after** the existing migrations, and, for a new
`MetricType`, decide whether it needs a case in `MetricType.allTime`. For a new `Platform`, also
set its `maxCollectionIntervalDays` in `Account.swift` — the longest sweep interval that still
loses no days, which `ResourceController.create` enforces.

## Scheduled jobs vs. jobs

For the deployment and container decision—especially when a new named queue needs its own
worker—see [queue-workers.md](queue-workers.md).

Two different protocols, two different workers:

- **`AsyncJob`** — dispatched with a payload, drained by `queues --queue metrics`.
- **`AsyncScheduledJob`** — no payload, run on a clock by `queues --scheduled`.

The scheduled jobs here (`CollectDueResources`, `CollectAccountStats`) only *enqueue*; the
actual syncing happens on the metrics queue. That split is deliberate: a slow sync can't delay
the next sweep. Schedule a new one in `configure.swift`:

```swift
app.queues.schedule(MySweep()).hourly().at(0)
```

Run exactly one scheduler process. Two would dispatch every due resource twice.

Note the two sweeps differ by *unit*: `CollectDueResources` is per-resource and interval-driven,
`CollectAccountStats` is per-account and fixed-monthly. An account-level figure folded into the
resource sweep would be fetched once per resource the account owns.

## Running it

```
just queues      # queues --queue metrics    — drains the syncs
just scheduled   # queues --scheduled        — runs the sweeps
```

`serve` does **not** drain the queue. Jobs live in Valkey/Redis (`REDIS_HOST`), so a dispatch
with nothing listening fails at dispatch time rather than queueing silently.

To exercise one job without waiting for a sweep, dispatch it from a route or call `dequeue`
directly from a test — which is what the sync tests do.

## Tests

Two suites cover different halves, and they need the `test` database (`just db`, then
`just test` — serial, because every suite migrates and reverts the shared database).

**`SyncJobTests`** drives a job's `dequeue` directly against a stubbed client. Add a case there
for a new job:

- `stubAPI(on:_:token:)` replaces both `app.client` and `app.secrets`, answers Vault reads
  automatically from the secret name in the URL, and returns a recording of every request — that
  recording is how the URL spelling gets pinned (`/orgs/` vs `/org/`, `expand[]` parameters).
- Routes match on **exact path**, query excluded, because GitHub's paths nest: `/repos/o/n` is a
  prefix of `/repos/o/n/traffic/clones`. Unmatched requests answer 404, so a job asking for
  something the test didn't anticipate fails loudly.
- Bodies are served as `application/json`. A scraped HTML endpoint needs a variant of the stub.
- Traffic days must be generated relative to now (`trafficJSON`), never hard-coded — the fold
  compares against today's UTC midnight, so fixed dates drift out of the window and silently
  stop being folded.

**`QueueSweepTests`** covers the routing and scheduling instead, using the in-memory driver via
`withQueueApp`, so it asserts *which* job a platform dispatches without running it:

```swift
#expect(app.queues.asyncTest.all(SyncGitHubRepoStats.self).map(\.id) == [try repo.requireID()])
```

Add a case here when you wire a platform into `dispatchSync` — this is the suite that would have
caught a job registered but never routed.

**`JobFailureTests`** covers what happens after a job gives up: the severity each `JobError` case
reports at, the backoff ladder, that a failing job is requeued rather than dropped, and that a
credential failure re-books the resource while a platform failure leaves the cadence alone.
`stubNotifier(on:)` installs a recording `FailureNotifier` so a test can assert on what an
operator would have been told without a webhook.

## Checklist

- [ ] Job file in `Sources/Insights/Queues/`, throwing `JobError`, writing after all fetches
- [ ] `BackoffRetrying` conformance and an `error(_:_:_:)` delegating to the shared helper
- [ ] `app.queues.add(...)` in `configure.swift`
- [ ] Platform case in `Queue+SyncDispatch.swift`, dispatched with `maxRetryCount:`
- [ ] All-time handling matches the API's shape (table above)
- [ ] Migration for any new enum case, plus `maxCollectionIntervalDays` for a new platform
- [ ] `SyncJobTests` case for the happy path and at least one failure
- [ ] `QueueSweepTests` case for the routing
- [ ] `just fmt`

#icicle-insights# #queues# #background-jobs# #platform-integrations# #developer-documentation#
