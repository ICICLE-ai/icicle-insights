import Fluent
import FluentSQL
import Foundation
import Logging
import Queues
import Testing
import Vapor
import XCTQueues

@testable import Insights

/// What happens after a sync job fails is now load-bearing: the severity decides whether anyone
/// is told, and the rebooking decides whether a repaired credential is noticed in an hour or in a
/// week. These pin both, plus the retry budget that has to be spent before either applies.
@Suite("Job failure handling", .serialized)
struct JobFailureTests {
  private struct Underlying: Error {}

  private func past(_ days: Int) -> Date {
    Date().addingTimeInterval(Double(-days) * 86_400)
  }

  /// A GitHub account with a vault and one repository, due now.
  private func makeDueRepo(on app: Application) async throws -> Resource {
    let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
    let accountID = try account.requireID()
    _ = try await makeVault(on: app.db, accountID: accountID)
    return try await makeResource(
      on: app.db, accountID: accountID, name: "insights", type: .repository,
      nextCollectionAt: past(1))
  }

  // MARK: - Scheduling state

  @Test
  func `A resource carries nullable collection-history fields`() async throws {
    try await withInsightsApp { app in
      let resource = try await makeDueRepo(on: app)

      // Nil on a fresh row: nothing has collected it yet, and the backoff anchors on createdAt
      // until something does.
      #expect(resource.lastCollectedAt == nil)
      #expect(resource.stallNotifiedAt == nil)

      let stamped = Date()
      resource.lastCollectedAt = stamped
      resource.stallNotifiedAt = stamped
      try await resource.save(on: app.db)

      let reloaded = try #require(try await Resource.find(resource.id, on: app.db))
      #expect(abs(try #require(reloaded.lastCollectedAt).timeIntervalSince(stamped)) < 1)
      #expect(abs(try #require(reloaded.stallNotifiedAt).timeIntervalSince(stamped)) < 1)
    }
  }

  @Test
  func `A successful sweep anchors the schedule on the success`() async throws {
    try await withQueueApp { app in
      let resource = try await makeDueRepo(on: app)
      // Left over from a previous outage: a success has to clear it, or the data-loss alert
      // would stay suppressed through the next one.
      resource.stallNotifiedAt = Date().addingTimeInterval(-86_400)
      try await resource.save(on: app.db)

      stubAPI(
        on: app,
        [
          .ok(
            "/repos/icicle-ai/insights",
            #"{"stargazers_count": 1, "forks_count": 1, "subscribers_count": 1}"#),
          .ok(
            "/repos/icicle-ai/insights/traffic/clones", #"{"count": 1, "uniques": 1, "clones": []}"#
          ),
          .ok(
            "/repos/icicle-ai/insights/traffic/views", #"{"count": 1, "uniques": 1, "views": []}"#),
        ])

      try await CollectDueResources().run(context: queueContext(for: app))
      try await app.queues.queue(.metrics).worker.run()

      let settled = try #require(try await Resource.find(resource.id, on: app.db))
      #expect(abs(try #require(settled.lastCollectedAt).timeIntervalSinceNow) < 60)
      #expect(settled.stallNotifiedAt == nil)
      // Lands one interval out from now. Dispatch and success run back-to-back in this test, so
      // a 60-second tolerance on its own cannot tell whether the schedule anchored on the success
      // or the dispatch that preceded it — that is what `lastCollectedAt` and `stallNotifiedAt`
      // above establish, since only the success path writes them.
      #expect(
        abs(
          try #require(settled.nextCollectionAt).timeIntervalSinceNow - 7 * 86_400) < 60)
    }
  }

  // MARK: - History backfill

  /// Drives `CollectionBackoff.backfillLastCollectedAt` directly rather than through `prepare`,
  /// for the same reason as the clamp tests below: migrations already ran once at app boot, so
  /// re-invoking `prepare` here would fail on the `.field()` calls for columns the schema already
  /// has.
  @Test
  func `The last-collected backfill uses the newest metric reading`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "insights", type: .repository)
      let id = try resource.requireID()

      let older = try await makeMetric(on: app.db, resourceID: id, type: .stars)
      older.recordedAt = past(3)
      try await older.save(on: app.db)

      let newestAt = past(1)
      let newest = try await makeMetric(on: app.db, resourceID: id, type: .views)
      newest.recordedAt = newestAt
      try await newest.save(on: app.db)

      let sql = try #require(app.db as? any SQLDatabase)
      try await CollectionBackoff.backfillLastCollectedAt(on: sql)

      let reloaded = try #require(try await Resource.find(id, on: app.db))
      #expect(abs(try #require(reloaded.lastCollectedAt).timeIntervalSince(newestAt)) < 1)
    }
  }

  /// A resource with no metrics at all has no evidence to backfill from, and must stay NULL
  /// rather than falsely claim a collection happened.
  @Test
  func `The last-collected backfill leaves a resource with no metrics untouched`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "insights", type: .repository)

      let sql = try #require(app.db as? any SQLDatabase)
      try await CollectionBackoff.backfillLastCollectedAt(on: sql)

      let reloaded = try #require(try await Resource.find(resource.id, on: app.db))
      #expect(reloaded.lastCollectedAt == nil)
    }
  }

  // MARK: - Cadence clamp

  /// Drives `CollectionBackoff.clampGitHubCadences` directly rather than through `prepare`:
  /// migrations already ran once at app boot, so re-invoking `prepare` here would fail on the
  /// `.field()` calls for columns the schema already has. The extraction exists for exactly this.
  @Test
  func `The GitHub cadence clamp lowers an over-cap resource to the new maximum`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "insights", type: .repository,
        collectionIntervalDays: 14)  // The old GitHub ceiling, above the new 7-day cap.

      let sql = try #require(app.db as? any SQLDatabase)
      try await CollectionBackoff.clampGitHubCadences(on: sql)

      let reloaded = try #require(try await Resource.find(resource.id, on: app.db))
      #expect(reloaded.collectionIntervalDays == 7)
    }
  }

  /// Proves the clamp's `platform = 'github'` predicate and `account_id` join actually
  /// discriminate — without this, a broken WHERE clause that touched every resource above 7 would
  /// still pass the sibling test above.
  @Test
  func `The GitHub cadence clamp leaves other platforms untouched`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "some-model", platform: .huggingface)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "model", type: .model,
        collectionIntervalDays: 14)  // Above 7, but within Hugging Face's own 30-day cap.

      let sql = try #require(app.db as? any SQLDatabase)
      try await CollectionBackoff.clampGitHubCadences(on: sql)

      let reloaded = try #require(try await Resource.find(resource.id, on: app.db))
      #expect(reloaded.collectionIntervalDays == 14)
    }
  }

  // MARK: - Classification

  @Test
  func `Only credential failures are critical`() {
    let missing = JobError.missingToken(id: UUID())
    #expect(missing.logLevel == .critical)
    #expect(missing.isCredentialFailure)
    #expect(missing.identifier == "missing_token")

    // GitHub rejects an expired token with either status, so both have to count.
    for status in [401, 403] {
      let rejected = JobError.apiRequestFailed(
        url: "https://api.github.com", statusCode: status, message: nil)
      #expect(rejected.logLevel == .critical)
      #expect(rejected.isCredentialFailure)
    }

    // A platform having a bad day is not something an operator can fix.
    let unavailable = JobError.apiRequestFailed(
      url: "https://api.github.com", statusCode: 503, message: nil)
    #expect(unavailable.logLevel == .warning)
    #expect(!unavailable.isCredentialFailure)

    let malformed = JobError.decodingFailed(url: "https://api.github.com", underlying: Underlying())
    #expect(malformed.logLevel == .error)
    #expect(!malformed.isCredentialFailure)
    #expect(malformed.identifier == "decoding_failed")
  }

  /// The vault, not the platform, is where a job's token comes from, so a `TapisClientError` is
  /// the credential failure most likely to actually happen — and it is not a `JobError`. The
  /// classification lives in the queue's failure handler, so `TapisClientError` itself stays a
  /// plain `AbortError` for the HTTP boundary; these assert through the observable behaviour.
  @Test
  func `An expired vault token alerts and re-books like any other credential failure`() async throws
  {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)
      resource.scheduleNextCollection()
      try await resource.save(on: app.db)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        TapisClientError.requestFailed(status: .unauthorized),
        .init(id: try resource.requireID()),
      )

      let alert = try #require(notifier.recorded.first)
      #expect(alert.severity == .critical)
      #expect(alert.identifier == "tapis_request_failed")
      #expect(alert.details.contains("TAPIS_TOKEN"))

      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
    }
  }

  /// Tapis itself being unavailable is not something a token rotation fixes, so it must not
  /// borrow the credential treatment from the cases that are.
  @Test
  func `An unavailable vault is not treated as a credential failure`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)
      resource.scheduleNextCollection()
      try await resource.save(on: app.db)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        TapisClientError.requestFailed(status: .badGateway),
        .init(id: try resource.requireID()),
      )

      #expect(notifier.recorded.first?.severity == .warning)
      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
    }
  }

  /// An error from neither family still has to produce a usable alert.
  @Test
  func `An unclassified error alerts as a platform failure`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app), Underlying(), .init(id: try resource.requireID()))

      let alert = try #require(notifier.recorded.first)
      #expect(alert.severity == .warning)
      #expect(alert.identifier == "unknown")
    }
  }

  /// The whole point of the `DebuggableError` conformance: without it `report(error:)` logs a
  /// reflected enum at `.warning` and the hand-written explanation is never reached.
  @Test
  func `A reported error carries its own reason rather than a reflected enum`() {
    let error = JobError.missingToken(id: UUID())
    #expect(error.reason.contains("has no access token"))
    #expect(error.description.contains("missing_token"))
    #expect(!error.suggestedFixes.isEmpty)
  }

  // MARK: - Retries

  @Test
  func `A failing sync is requeued rather than dropped`() async throws {
    try await withQueueApp { app in
      _ = try await makeDueRepo(on: app)
      // 503 is retryable, and every route not named here answers 404, so the first call fails.
      stubAPI(on: app, [.failing("/repos/icicle-ai/insights", .serviceUnavailable)])

      try await CollectDueResources().run(context: queueContext(for: app))
      let dispatched = try #require(app.queues.asyncTest.jobs.values.first)
      #expect(dispatched.maxRetryCount == syncJobMaxRetryCount)

      try await app.queues.queue(.metrics).worker.run()

      // Requeued, not cleared: the worker rewrites the job with one attempt spent and a delay,
      // then leaves it alone because the delay has not elapsed.
      #expect(app.queues.asyncTest.queue.count == 1)
      let retried = try #require(app.queues.asyncTest.jobs.values.first)
      #expect(retried.attempts == 1)
      #expect(retried.delayUntil != nil)
    }
  }

  @Test
  func `Backoff grows and never returns immediately`() {
    let job = SyncGitHubRepoStats()
    #expect(job.nextRetryIn(attempt: 1) == 30)
    #expect(job.nextRetryIn(attempt: 2) == 120)
    #expect(job.nextRetryIn(attempt: 3) == 480)
  }

  // MARK: - Alerting

  @Test
  func `An exhausted credential failure alerts and names the resource`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.missingToken(id: resource.$account.id),
        .init(id: try resource.requireID()),
      )

      let alert = try #require(notifier.recorded.first)
      #expect(alert.severity == .critical)
      #expect(alert.identifier == "missing_token")
      #expect(alert.job == "SyncGitHubRepoStats")
      // The owner/name form is what an operator recognizes; a bare UUID is not actionable.
      #expect(alert.subject == "icicle-ai/insights")
      // `.long` format, so the alert carries the fix and the log does not have to.
      #expect(alert.details.contains("vault entry"))

      let persisted = try #require(try await JobFailure.query(on: app.db).first())
      #expect(persisted.$resource.id == resource.id)
      #expect(persisted.identifier == "missing_token")
      #expect(persisted.severity == "critical")
      #expect(persisted.subject == "icicle-ai/insights")
    }
  }

  @Test
  func `A platform failure alerts at warning rather than critical`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.decodingFailed(url: "https://api.github.com", underlying: Underlying()),
        .init(id: try resource.requireID()),
      )

      #expect(notifier.recorded.first?.severity == .warning)
    }
  }

  // MARK: - Rebooking

  @Test
  func `A credential failure re-books the resource for the next hourly sweep`() async throws {
    try await withInsightsApp { app in
      _ = stubNotifier(on: app)
      // A week out is where the sweep left it: it advances the due date on dispatch, long before
      // the job fails. Without rebooking, a token fixed today is not noticed until next week.
      let resource = try await makeDueRepo(on: app)
      resource.scheduleNextCollection()
      try await resource.save(on: app.db)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.missingToken(id: resource.$account.id),
        .init(id: try resource.requireID()),
      )

      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
    }
  }

  @Test
  func `A platform failure re-books within the cap instead of costing an interval`() async throws {
    try await withInsightsApp { app in
      _ = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)
      // A week out is where the sweep left it — it advances the due date on dispatch, long before
      // the job fails. Leaving it there is what let gaps compound past the retention window.
      resource.lastCollectedAt = past(7)
      resource.scheduleNextCollection()
      try await resource.save(on: app.db)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.decodingFailed(url: "https://api.github.com", underlying: Underlying()),
        .init(id: try resource.requireID()),
      )

      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      // Barely overdue, so the floor applies: the next hourly sweep, not next week.
      #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
    }
  }

  @Test
  func `A long-failing resource backs off but stays inside the window`() async throws {
    try await withInsightsApp { app in
      _ = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)
      // Nine days since the last success on a 7-day cadence: two days overdue, so the ceiling.
      resource.lastCollectedAt = past(9)
      try await resource.save(on: app.db)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
        .init(id: try resource.requireID()),
      )

      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(rebooked.timeIntervalSinceNow - 12 * 3600) < 60)
    }
  }

  // MARK: - Alert delivery is never load-bearing

  /// `QueueWorker` clears a job only after `error(_:_:_:)` returns, so an alert channel that
  /// throws would strand the job and stop the worker. `FailureNotifier.notify` is non-throwing
  /// for exactly this reason; this proves the Slack implementation honours it when Slack is down.
  @Test
  func `An unreachable alert channel does not fail the job`() async throws {
    try await withInsightsApp { app in
      app.notifier = SlackNotifier(
        client: StubClient(eventLoop: app.eventLoopGroup.any(), status: .internalServerError),
        criticalWebhookURL: "https://hooks.slack.example/broken",
        warningWebhookURL: "https://hooks.slack.example/broken",
        logger: app.logger,
      )
      let resource = try await makeDueRepo(on: app)

      // The assertion is that this returns at all.
      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.missingToken(id: resource.$account.id),
        .init(id: try resource.requireID()),
      )

      // And that the rebooking still happened despite the channel being down.
      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
    }
  }

  // MARK: - Retention window

  @Test
  func `Passing the retention window raises its own alert, once`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)
      // 20 days since the last success, against GitHub's 14-day traffic window: days have already
      // aged out and cannot be reconstructed by any watermark.
      resource.lastCollectedAt = past(20)
      try await resource.save(on: app.db)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
        .init(id: try resource.requireID()),
      )

      let breach = try #require(
        notifier.recorded.first { $0.identifier == "collection_window_exceeded" })
      #expect(breach.severity == .critical)
      #expect(breach.subject == "icicle-ai/insights")
      #expect(breach.details.contains("cannot be recovered"))

      let stamped = try #require(try await Resource.find(resource.id, on: app.db))
      #expect(stamped.stallNotifiedAt != nil)

      // The breach persists its own `JobFailure` row, distinct from the underlying error's —
      // they are different facts, and only asserting the alert leaves that split unpinned.
      #expect(
        try await JobFailure.query(on: app.db)
          .filter(\.$identifier == "collection_window_exceeded").count() == 1)

      // Second failure in the same outage: the underlying error still alerts, the breach does not
      // repeat. The capped backoff already spaces those out; repeating this one would double it.
      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
        .init(id: try resource.requireID()),
      )
      #expect(notifier.recorded.filter { $0.identifier == "collection_window_exceeded" }.count == 1)
      #expect(
        try await JobFailure.query(on: app.db)
          .filter(\.$identifier == "collection_window_exceeded").count() == 1)
    }
  }

  @Test
  func `The Hub never raises a data-loss alert`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let account = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID)
      let resource = try await makeResource(
        on: app.db, accountID: accountID, name: "insights", type: .model)
      // Far past any window, and still not a loss: the Hub reports downloadsAllTime outright, so
      // the next successful sweep restores the correct total.
      resource.lastCollectedAt = past(90)
      try await resource.save(on: app.db)

      try await SyncHuggingFaceHubStats().error(
        queueContext(for: app),
        JobError.apiRequestFailed(url: "https://huggingface.co", statusCode: 503, message: nil),
        .init(id: try resource.requireID()),
      )

      #expect(!notifier.recorded.contains { $0.identifier == "collection_window_exceeded" })
    }
  }

  // MARK: - Account jobs

  @Test
  func `An account credential failure alerts without a due date to re-book`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let accountID = try account.requireID()

      try await SyncGitHubOrgStats().error(
        queueContext(for: app),
        JobError.missingToken(id: accountID),
        .init(id: accountID),
      )

      let alert = try #require(notifier.recorded.first)
      #expect(alert.severity == .critical)
      #expect(alert.subject == "icicle-ai")
      #expect(alert.job == "SyncGitHubOrgStats")

      let persisted = try #require(try await JobFailure.query(on: app.db).first())
      #expect(persisted.$account.id == accountID)
      #expect(persisted.$resource.id == nil)
    }
  }

  // MARK: - Backoff policy

  @Test
  func `Backoff starts at an hour and never dips below it`() {
    // A resource failing right on schedule is barely overdue; retry on the next sweep.
    #expect(CollectionSchedule.retryDelay(overdueBy: 0) == 3600)
    #expect(CollectionSchedule.retryDelay(overdueBy: -86_400) == 3600)
    #expect(CollectionSchedule.retryDelay(overdueBy: 3600) == 3600)
  }

  @Test
  func `Backoff grows with how overdue the resource is, then caps`() {
    // A quarter of the overdue time: gentle enough that the first day keeps retrying hourly,
    // steep enough to reach the ceiling after roughly two days of continuous failure.
    #expect(CollectionSchedule.retryDelay(overdueBy: 8 * 3600) == 2 * 3600)
    #expect(CollectionSchedule.retryDelay(overdueBy: 24 * 3600) == 6 * 3600)

    // The cap has to stay far inside `retention - interval` (7 days at GitHub's cap), or the
    // policy itself would be what loses the data.
    #expect(CollectionSchedule.retryDelay(overdueBy: 2 * 86_400) == 12 * 3600)
    #expect(CollectionSchedule.retryDelay(overdueBy: 60 * 86_400) == 12 * 3600)
  }

  @Test
  func `Overdue time is measured from the last success, not the last attempt`() {
    let now = Date()
    let lastWeek = now.addingTimeInterval(-7 * 86_400)

    // Succeeded 7 days ago on a 7-day cadence: due now, not yet overdue.
    #expect(
      abs(
        CollectionSchedule.overdue(
          now: now, lastSuccess: lastWeek, createdAt: lastWeek, intervalDays: 7)) < 1)

    // Never succeeded: createdAt is the anchor, so a resource created 10 days ago on a 7-day
    // cadence is 3 days overdue rather than indefinitely patient.
    let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
    #expect(
      abs(
        CollectionSchedule.overdue(
          now: now, lastSuccess: nil, createdAt: tenDaysAgo, intervalDays: 7) - 3 * 86_400) < 1)
  }

  /// `CollectionSchedule.maximumRetry` staying far inside `retentionWindowDays -
  /// maxCollectionIntervalDays` is documented in three places and checked nowhere. A future
  /// platform with a retention window could set its cadence cap too close to it, silently.
  @Test
  func `The retry ceiling stays inside every platform's headroom`() {
    for platform in Platform.allCases {
      guard let window = platform.retentionWindowDays else { continue }
      // Cap at half the window, so one missed collection still leaves room.
      #expect(platform.maxCollectionIntervalDays * 2 <= window)
      // And the backoff ceiling must never eat the remaining headroom.
      #expect(
        CollectionSchedule.maximumRetry
          < Double(window - platform.maxCollectionIntervalDays) * 86_400)
    }
  }
}
