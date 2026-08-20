import Fluent
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
      let scheduled = try #require(resource.nextCollectionAt)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        TapisClientError.requestFailed(status: .badGateway),
        .init(id: try resource.requireID()),
      )

      #expect(notifier.recorded.first?.severity == .warning)
      let unchanged = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(unchanged.timeIntervalSince(scheduled)) < 1)
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
  func `A platform failure leaves the normal cadence alone`() async throws {
    try await withInsightsApp { app in
      _ = stubNotifier(on: app)
      let resource = try await makeDueRepo(on: app)
      resource.scheduleNextCollection()
      try await resource.save(on: app.db)
      let scheduled = try #require(resource.nextCollectionAt)

      try await SyncGitHubRepoStats().error(
        queueContext(for: app),
        JobError.decodingFailed(url: "https://api.github.com", underlying: Underlying()),
        .init(id: try resource.requireID()),
      )

      let unchanged = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(unchanged.timeIntervalSince(scheduled)) < 1)
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
    }
  }
}
