import Fluent
import FluentSQL
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
  func `A due GHCR resource dispatches SyncGHCRStats and is rebooked`() async throws {
    try await withQueueApp { app in
      // GHCR sat in the skip branch until its collector shipped. This pins that it now routes like
      // any other platform with a job, rather than silently regressing to "logged and skipped".
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .ghcr)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        type: .container,
        nextCollectionAt: past(1),
      )

      try await CollectDueResources().run(context: queueContext(for: app))

      #expect(
        app.queues.asyncTest.all(SyncGHCRStats.self).map(\.id) == [try resource.requireID()])
      let rebooked = try #require(
        try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(rebooked > Date())
    }
  }

  @Test
  func `A platform with no sync job is skipped but still rebooked`() async throws {
    try await withQueueApp { app in
      // npm is legitimately in the catalog, just not collectable yet, so the sweep logs and
      // moves on rather than throwing and stranding the resource as permanently due.
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .npm)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        type: .package,
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

  /// The outage an account delete used to cause. The due set is one query, and a plain eager
  /// load of a soft-deleted account throws `missingParent`, so this sweep threw before
  /// dispatching anything and the healthy account went uncollected too.
  @Test
  func `A resource under a deleted account is skipped without stopping the sweep`() async throws {
    try await withQueueApp { app in
      let retired = try await makeAccount(on: app.db, name: "retired")
      let orphanDue = past(1)
      let orphan = try await makeResource(
        on: app.db, accountID: try retired.requireID(), name: "orphan",
        nextCollectionAt: orphanDue)
      // Deleted straight through Fluent, as an older deployment or a hand edit could have done.
      // The API now refuses this while the account still owns a resource.
      try await retired.delete(on: app.db)

      let healthy = try await makeAccount(on: app.db, name: "healthy")
      let collected = try await makeResource(
        on: app.db, accountID: try healthy.requireID(), name: "collected",
        nextCollectionAt: past(1))

      try await CollectDueResources().run(context: queueContext(for: app))

      #expect(
        app.queues.asyncTest.all(SyncGitHubRepoStats.self).map(\.id) == [
          try collected.requireID()
        ])

      // Neither dispatched nor re-booked: its due date stands, so restoring the account resumes
      // collection on the next sweep instead of a full interval later.
      let untouched = try #require(
        try await Resource.find(orphan.id, on: app.db)?.nextCollectionAt)
      #expect(abs(untouched.timeIntervalSince(orphanDue)) < 1)
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

  /// The same proof for GHCR, whose job is registered separately and could drift on its own: the
  /// sweep enqueues it, and the worker finds a job by that name, runs it, and writes both figures.
  @Test
  func `A swept GHCR resource runs end to end through the worker`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .ghcr)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        name: "insights",
        type: .container,
        nextCollectionAt: past(1),
      )

      let page = try ghcrFixture("package-page-2026-09.html")
      stubPagedAPI(on: app) { url in
        guard url == "https://github.com/orgs/icicle-ai/packages/container/package/insights"
        else { return nil }
        return ClientResponse(status: .ok, body: ByteBuffer(string: page))
      }

      try await CollectDueResources().run(context: queueContext(for: app))
      try await app.queues.queue(.metrics).worker.run()

      #expect(app.queues.asyncTest.queue.isEmpty)
      let readings = try await Metric.query(on: app.db)
        .filter(\.$resource.$id == resource.requireID())
        .all()
        .reduce(into: [MetricType: Double]()) { $0[$1.type] = $1.reading }
      #expect(readings[.pulls] == 38)
      #expect(readings[.pullsAllTime] == 302)
    }
  }

  // MARK: - Unscheduled GHCR backfill

  /// Drives `ScheduleGHCRResources.scheduleUnscheduledGHCRResources` directly: migrations have
  /// already run once at app boot, so the test calls the backfill itself after inserting rows.
  @Test
  func `The GHCR backfill makes an unscheduled container due, and the sweep then dispatches it`()
    async throws
  {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .ghcr)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "insights", type: .container)

      let sql = try #require(app.db as? any SQLDatabase)
      try await ScheduleGHCRResources.scheduleUnscheduledGHCRResources(on: sql)

      let booked = try #require(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(booked.timeIntervalSinceNow) < 60)

      try await CollectDueResources().run(context: queueContext(for: app))
      #expect(
        app.queues.asyncTest.all(SyncGHCRStats.self).map(\.id) == [try resource.requireID()])
    }
  }

  /// npm and PyPI are left unscheduled on purpose, and so is every other platform: the backfill
  /// is for GHCR rows only. A scheduled GHCR row keeps its own date, and deleted rows stay out.
  @Test
  func `The GHCR backfill leaves every other row alone`() async throws {
    try await withQueueApp { app in
      var untouched: [Resource] = []
      for platform in [Platform.npm, .pypi, .github, .huggingface, .patra] {
        let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: platform)
        untouched.append(
          try await makeResource(on: app.db, accountID: try account.requireID(), name: "pkg"))
      }

      let ghcr = try await makeAccount(on: app.db, name: "icicle-ai", platform: .ghcr)
      let ghcrID = try ghcr.requireID()
      let scheduledAt = future(3)
      let scheduled = try await makeResource(
        on: app.db, accountID: ghcrID, name: "scheduled", type: .container,
        nextCollectionAt: scheduledAt)
      let deleted = try await makeResource(
        on: app.db, accountID: ghcrID, name: "deleted", type: .container)
      try await deleted.delete(on: app.db)

      let orphanAccount = try await makeAccount(on: app.db, name: "gone", platform: .ghcr)
      let orphan = try await makeResource(
        on: app.db, accountID: try orphanAccount.requireID(), name: "orphan", type: .container)
      try await orphanAccount.delete(on: app.db)

      let sql = try #require(app.db as? any SQLDatabase)
      try await ScheduleGHCRResources.scheduleUnscheduledGHCRResources(on: sql)

      for resource in untouched + [orphan] {
        #expect(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt == nil)
      }
      let kept = try #require(try await Resource.find(scheduled.id, on: app.db)?.nextCollectionAt)
      #expect(abs(kept.timeIntervalSince(scheduledAt)) < 1)
      let stillDeleted = try #require(
        try await Resource.query(on: app.db).withDeleted()
          .filter(\.$id == deleted.requireID()).first())
      #expect(stillDeleted.nextCollectionAt == nil)
    }
  }
}
