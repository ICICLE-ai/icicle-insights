# Add a collector

Collect metrics from a new platform. For developers.

Three files. Registration gives workers a decoder; routing puts the payload on a queue.

| # | File | Does |
|---|---|---|
| 1 | `Sources/Insights/Queues/Collectors/SyncExampleStats.swift` | The work |
| 2 | `Sources/Insights/configure.swift` | Registers the job so workers can decode it |
| 3 | `Sources/Insights/Queues/Collectors/SyncDispatch.swift` | Routes a platform to the job |

**Controllers need no change.** Both the hourly sweep and creation-time collection call the same
routing extension, so wiring step 3 lights up both at once.

## 1. Write the job

```swift
struct ExampleResource: Codable {
  let id: UUID
}

struct SyncExampleStats: AsyncJob, BackoffRetrying {
  typealias Payload = ExampleResource

  func error(_ context: QueueContext, _ error: any Error, _ payload: ExampleResource) async throws {
    await context.reportResourceSyncFailure(error, job: Self.name, resourceID: payload.id)
  }

  func dequeue(_ context: QueueContext, _ payload: ExampleResource) async throws {
    guard
      let resource = try await Resource.query(on: context.application.db)
        .filter(\.$id == payload.id)
        .with(\.$account, withDeleted: true)
        .first()
    else {
      context.entryVanished(id: payload.id, job: Self.name)
      return
    }

    guard !resource.accountIsDeleted else {
      context.orphanSkipped(resource, job: Self.name)
      return
    }

    // fetch everything first

    try await context.application.db.transaction { db in
      // write every metric through `db`

      try await resource.recordSuccessfulCollection(on: db)
    }
  }
}
```

Follow seven conventions the existing jobs share.

**Payloads carry only an identifier.** The job re-reads the row, so a resource edited between
dispatch and execution is collected as it is now.

**Fetch everything, then write.** Collect all responses before writing any metric. A failure partway
through otherwise leaves gauges stranded without the traffic rows sharing their timestamp. There is
a test for this.

**A missing subject is not a failure.** If the row is gone, call `entryVanished` and return. The
worker decides whether to retry from the remaining attempt count alone, so throwing spends four
attempts across roughly ten minutes rediscovering that a row is deleted.

**Load the account with `withDeleted: true`.** Then skip a resource whose account is deleted with
`orphanSkipped`. A plain eager load throws `missingParent` instead, and the job spends its retries.

**Write in one transaction.** A failure after the first row would otherwise leave it for the retry
to duplicate. There is a test for this too.

**Resolve credentials through `SecretProvider`.** Never reach for a vault client directly.

**Record success last.** Call `resource.recordSuccessfulCollection(on:)` as the final statement
inside the transaction, after every fetch and fold. It anchors the backoff and the next due date on
this success; called any earlier, a partial sweep would count as one.

## When the platform breaks the pattern

Three real deviations exist: two in Patra's collectors, and one in GHCR's.

**A public API needs no credential.** `SyncPatraCatalog` and `SyncPatraDeployments` send no
token, unlike every other collector. Patra's endpoints answer private records to an authenticated
caller, and this service's API and dashboard are public, so a token would leak exactly what
`is_private` exists to hide. Skip `SecretProvider` entirely when a platform's read endpoints are
already public — do not resolve a credential just because every other collector does.

**An account-level discovery job never calls `recordSuccessfulCollection`.** `SyncPatraCatalog`
finds and creates resources; it writes no metric and touches many resources in one run, so it has
no single resource's cadence to anchor. Only a per-resource job — `SyncPatraDeployments` here —
calls it. If your new platform needs its own catalog discovery step, model it on
`SyncPatraCatalog` and `CollectPatraCatalog`, not on the per-resource template above.

**A platform with no API is scraped.** `SyncGHCRStats` reads GitHub's public package page, because
no API reports GHCR downloads. If you must scrape a page:

1. Put the parsing in its own pure type that takes HTML and returns values, like `GHCRPackagePage`.
   It then needs no database or network to test.
2. Throw `JobError.pageLayoutChanged` for anything missing or unreadable. Never return zero or a
   partial result.
3. Save real pages, trimmed to the parts the parser reads, under `Tests/Fixtures/<Platform>/`. Test
   the parser against them, and against copies with each element removed.

Why GHCR is scraped, and what that costs, is in
[ADR 009](../explanation/decisions/009-scraping-ghcr.md).

## 2. Register it

In `configure.swift`, beside the others:

```swift
app.queues.add(SyncExampleStats())
```

Without this the worker cannot decode the payload and the job fails at dequeue.

## 3. Route the platform

In `Collectors/SyncDispatch.swift`, move the platform out of the skipped list:

```swift
case .example:
  try await dispatch(
    SyncExampleStats.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
```

## Handle the metric shape

Decide which shape the platform reports. Getting this wrong corrupts totals silently.

| Shape | Use |
|---|---|
| Current value that can fall | Write the reading. No all-time row |
| Overlapping daily window | `Metric.foldDailyIntoAllTime` |
| Provider's own lifetime figure | `Metric.setAllTime` |
| Genuine non-overlapping delta | `Metric.addToAllTime` |

Never add a rolling window directly to a total. See [Watermarks](../explanation/watermarks.md).

If the platform has a retention window, set `retentionWindowDays` on the platform enum, and cap
`maxCollectionIntervalDays` at half of it.

## Test it

Follow the existing suites:

| Suite | Add |
|---|---|
| `SyncJobTests` | The happy path against a stubbed API, plus every error branch |
| `QueueSweepTests` | That the platform routes to your job and re-books correctly |
| `MetricAllTimeTests` | Fold behaviour, if the platform reports a rolling window |
| A parser suite | The page parser against saved pages, if the platform is scraped. See `GHCRPackagePageTests` |

`stubAPI` matches paths exactly, because `/repos/o/n` is a prefix of `/repos/o/n/traffic/clones`.
Assert on the URL the job builds; that is what catches a wrong query parameter.

```bash
just test
```

## Verify against a real platform

Register an account and a resource for the new platform, then:

```bash
just collect --force
```

Watch the worker log for the actual request and the written rows.

## Then

Update [Collection schedule](../reference/collection-schedule.md) with the platform's metrics,
cadence cap, and job name.

#icicle-insights# #How-To# #Developer# #collection#
