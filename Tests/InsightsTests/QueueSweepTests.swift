import Fluent
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues

@testable import Insights

/// The scheduled sweeps are the only thing that ever enqueues a sync in production, and they
/// fail quietly: an unregistered job name is dropped with a log line, and a resource that fails
/// to dispatch is skipped on purpose. These pin what actually reaches the queue.
@Suite("Queue sweeps", .serialized)
struct QueueSweepTests {
  private func past(_ days: Int) -> Date {
    Date().addingTimeInterval(Double(-days) * 86_400)
  }

  private func future(_ days: Int) -> Date {
    Date().addingTimeInterval(Double(days) * 86_400)
  }

  @Test
  func `Only resources due now are dispatched`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      let due = try await makeResource(
        on: app.db, accountID: accountID, name: "due", nextCollectionAt: past(1))
      _ = try await makeResource(
        on: app.db, accountID: accountID, name: "later", nextCollectionAt: future(1))
      // Nil never matches the sweep's `<= now` filter, so an uncollected resource stays out
      // until something books it.
      _ = try await makeResource(on: app.db, accountID: accountID, name: "unscheduled")

      try await CollectDueResources().run(context: queueContext(for: app))

      let dispatched = app.queues.asyncTest.all(SyncGitHubRepoStats.self)
      #expect(dispatched.map(\.id) == [try due.requireID()])
    }
  }

  @Test
  func `A dispatched resource is rebooked from now, not its old due date`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      // Long overdue: rebooking from the stale date would land in the past and make the
      // resource due again on the very next sweep, once per interval missed.
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        nextCollectionAt: past(30),
        collectionIntervalDays: 7,
      )

      try await CollectDueResources().run(context: queueContext(for: app))

      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(rebooked > Date())
      #expect(abs(rebooked.timeIntervalSince(future(7))) < 60)
    }
  }

  @Test
  func `Each platform routes to its own sync job`() async throws {
    try await withQueueApp { app in
      let github = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let hub = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let repo = try await makeResource(
        on: app.db, accountID: try github.requireID(), nextCollectionAt: past(1))
      let model = try await makeResource(
        on: app.db, accountID: try hub.requireID(), nextCollectionAt: past(1))

      try await CollectDueResources().run(context: queueContext(for: app))

      // Platform picks the job, not `Resource.type` — a `.model` on GitHub would still be
      // reported on by the repo endpoints.
      #expect(
        app.queues.asyncTest.all(SyncGitHubRepoStats.self).map(\.id) == [try repo.requireID()])
      #expect(
        app.queues.asyncTest.all(SyncHuggingFaceHubStats.self).map(\.id) == [try model.requireID()]
      )
    }
  }

  @Test
  func `A due Patra resource dispatches SyncPatraDeployments and is rebooked`() async throws {
    try await withQueueApp { app in
      // Patra is the platform the skip branch in `dispatchSync` used to swallow — this pins
      // that it now routes like any other platform with a job, rather than silently regressing
      // to "logged and skipped" the next time that switch is touched.
      let account = try await makeAccount(on: app.db, name: "icicleai", platform: .patra)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), nextCollectionAt: past(1))

      try await CollectDueResources().run(context: queueContext(for: app))

      #expect(
        app.queues.asyncTest.all(SyncPatraDeployments.self).map(\.id) == [try resource.requireID()]
      )
      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(rebooked > Date())
    }
  }

  @Test
  func `A platform with no sync job is skipped but still rebooked`() async throws {
    try await withQueueApp { app in
      // GHCR is legitimately in the catalog, just not collectable yet, so the sweep logs and
      // moves on rather than throwing and stranding the resource as permanently due.
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .ghcr)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        type: .container,
        nextCollectionAt: past(1),
      )

      try await CollectDueResources().run(context: queueContext(for: app))

      #expect(app.queues.asyncTest.queue.isEmpty)
      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(rebooked > Date())
    }
  }

  @Test
  func `A dispatch failure leaves the resource due and the sweep continues`() async throws {
    let driver = FlakyQueuesDriver()
    try await withInsightsApp(setUp: { $0.queues.use(custom: driver) }) { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      let wasDue = past(1)
      for name in ["first", "second"] {
        _ = try await makeResource(
          on: app.db, accountID: accountID, name: name, nextCollectionAt: wasDue)
      }

      // One dispatch fails. The sweep must not abort, and the failed resource must keep its
      // due date so the next sweep retries it.
      try await CollectDueResources().run(context: queueContext(for: app))

      // Which resource failed depends on the order `all()` happens to return, so count rather
      // than name them.
      let dates = try await Resource.query(on: app.db).all().compactMap(\.nextCollectionAt)
      #expect(dates.filter { $0 < Date() }.count == 1)
      #expect(dates.filter { $0 > Date() }.count == 1)
      #expect(driver.stored.withLockedValue { $0.count } == 1)
    }
  }

  @Test
  func `Account stats dispatch one job per GitHub account`() async throws {
    try await withQueueApp { app in
      let first = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let second = try await makeAccount(on: app.db, name: "sci-ai", platform: .github)
      // Followers are a GitHub-only figure here; the Hub account must not be swept for them.
      _ = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)

      try await CollectAccountStats().run(context: queueContext(for: app))

      let dispatched = app.queues.asyncTest.all(SyncGitHubOrgStats.self).map(\.id).sorted {
        $0.uuidString < $1.uuidString
      }
      let expected = [try first.requireID(), try second.requireID()].sorted {
        $0.uuidString < $1.uuidString
      }
      #expect(dispatched == expected)
    }
  }

  /// The one test that proves the names registered in `configure` match what `dispatchSync`
  /// enqueues. A mismatch is invisible otherwise: `QueueWorker` discards a job it cannot name
  /// with nothing but a warning, so the queue drains cleanly and collects nothing.
  @Test
  func `A swept resource runs end to end through the worker`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID)
      let resource = try await makeResource(
        on: app.db,
        accountID: accountID,
        name: "insights",
        type: .repository,
        nextCollectionAt: past(1),
      )

      stubAPI(
        on: app,
        [
          .ok(
            "/repos/icicle-ai/insights",
            #"{"stargazers_count": 12, "forks_count": 3, "subscribers_count": 5}"#),
          .ok(
            "/repos/icicle-ai/insights/traffic/clones",
            #"{"count": 40, "uniques": 10, "clones": []}"#),
          .ok(
            "/repos/icicle-ai/insights/traffic/views",
            #"{"count": 90, "uniques": 30, "views": []}"#),
        ])

      try await CollectDueResources().run(context: queueContext(for: app))
      try await app.queues.queue(.metrics).worker.run()

      #expect(app.queues.asyncTest.queue.isEmpty)
      let readings = try await Metric.query(on: app.db)
        .filter(\.$resource.$id == resource.requireID())
        .all()
        .reduce(into: [MetricType: Double]()) { $0[$1.type] = $1.reading }
      #expect(readings[.stars] == 12)
      #expect(readings[.clones] == 40)
      #expect(readings[.views] == 90)
    }
  }
}
