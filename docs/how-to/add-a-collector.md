# Add a collector

Collect metrics from a new platform. For developers.

Three files. Registration gives workers a decoder; routing puts the payload on a queue.

| # | File | Does |
|---|---|---|
| 1 | `Sources/Insights/Queues/Collectors/SyncXStats.swift` | The work |
| 2 | `Sources/Insights/configure.swift` | Registers the job so workers can decode it |
| 3 | `Sources/Insights/Queues/Collectors/SyncDispatch.swift` | Routes a platform to the job |

**Controllers need no change.** Both the hourly sweep and creation-time collection call the same
routing extension, so wiring step 3 lights up both at once.

## 1. Write the job

```swift
struct GHCRResource: Codable {
  let id: UUID
}

struct SyncGHCRStats: AsyncJob, BackoffRetrying {
  typealias Payload = GHCRResource

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
      context.entryVanished(id: payload.id, job: Self.name)
      return
    }

    // fetch everything, then write

    try await resource.recordSuccessfulCollection(on: context.application.db)
  }
}
```

Follow five conventions the existing jobs share.

**Payloads carry only an identifier.** The job re-reads the row, so a resource edited between
dispatch and execution is collected as it is now.

**Fetch everything, then write.** Collect all responses before writing any metric. A failure partway
through otherwise leaves gauges stranded without the traffic rows sharing their timestamp. There is
a test for this.

**A missing subject is not a failure.** If the row is gone, call `entryVanished` and return. The
worker decides whether to retry from the remaining attempt count alone, so throwing spends four
attempts across roughly ten minutes rediscovering that a row is deleted.

**Resolve credentials through `SecretProvider`.** Never reach for a vault client directly.

**Record success last.** Call `resource.recordSuccessfulCollection(on:)` as the final statement,
after every fetch and fold. It anchors the backoff and the next due date on this success; called
any earlier, a partial sweep would count as one.

## 2. Register it

In `configure.swift`, beside the others:

```swift
app.queues.add(SyncGHCRStats())
```

Without this the worker cannot decode the payload and the job fails at dequeue.

## 3. Route the platform

In `Collectors/SyncDispatch.swift`, move the platform out of the skipped list:

```swift
case .ghcr:
  try await dispatch(SyncGHCRStats.self, .init(id: resource.id!), on: context)
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
