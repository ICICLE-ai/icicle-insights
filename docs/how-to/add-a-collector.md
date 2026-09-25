# Add a collector

How to start collecting a platform that Insights does not read yet, for developers. Read
[How collection works](../explanation/how-collection-works.md) first. npm and PyPI are listed but
deliberately left uncollected; see [Metrics](../reference/metrics.md).

`Sources/Insights/Queues/Collectors/SyncGHCRStats.swift` is the shortest complete example.

## Steps

1. **Pick the metric shape.** Decide, for each figure, whether the platform reports a total, a
   trailing window or a lifetime count. Use existing `MetricType` cases where they fit; a new case
   needs a migration that extends the `metric_type` enum.
2. **Write the job** in `Sources/Insights/Queues/Collectors/Sync{Platform}Stats.swift`, here
   `SyncExampleStats`:
   - a `Codable` payload holding the resource `id`
   - `struct SyncExampleStats: AsyncJob, BackoffRetrying`
   - `error(_:_:_:)` calling `context.reportResourceSyncFailure(error, job: Self.name, resourceID:)`
3. **Load the resource safely** in `dequeue`. Query it `.with(\.$account, withDeleted: true)`. Call
   `context.entryVanished` when it is gone and `context.orphanSkipped` when its account is deleted,
   then return without throwing.
4. **Fetch everything before writing.** Throw `JobError.apiRequestFailed` for a bad status and
   `JobError.decodingFailed` for a body that will not parse.
5. **Write in one transaction**, in `context.application.db.transaction`:
   - create the snapshot `Metric` rows
   - `Metric.setAllTime` for a lifetime figure the platform reports itself
   - `Metric.foldDailyIntoAllTime` for per-day windows that must be summed by Insights
   - `resource.recordSuccessfulCollection(on: db)` last
6. **Register the job** in `configure.swift` with `app.queues.add(SyncExampleStats())`.
7. **Route to it** in `SyncDispatch.swift`, and make `Platform.hasCollector` true for it. The sweep
   and **Collect now** both skip a platform where it is false. A platform that is not listed yet
   also needs a `Platform` case, added last, and a migration that extends the `platform` enum.
8. **Check the limits** in `Platform` (`Models/Account.swift`): `maxCollectionIntervalDays` and
   `retentionWindowDays`. A platform that drops daily data needs a cadence well inside its window.
9. **Use a stored token only if the data is private.** GHCR and Patra read public pages without
   one, which also keeps private data off a public dashboard.

## Tests

- In `SyncJobTests`, stub the platform with `stubAPI` or `stubPagedAPI` from `TestSupport.swift`.
  Cover the happy path, a 404, a malformed body, and a retry after a failed write.
- In `QueueSweepTests`, assert the platform now dispatches the new job.
- Run `just test`. See [Run the tests](run-the-tests.md).

## Docs and dashboard

- Update the platform rows in [Metrics](../reference/metrics.md).
- Set the platform to `true` in `HAS_COLLECTOR` in `web/src/lib/admin/collect.ts`, or the console
  keeps **Collect now** blocked for it.
- If you added a `MetricType`, add its label and kind to `METRICS` in `web/src/lib/format.ts` and
  regenerate the API types. See [Develop the dashboard](develop-the-dashboard.md).

## Check it worked

Run the stack, add a resource on the platform, and watch **Operations** and **Metrics** in the
admin console. See [Collect now](collect-now.md).

#icicle-insights# #How-To# #Developer#
