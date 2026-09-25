import Fluent
import Foundation
import Queues
import Testing
import VaporTesting
import XCTQueues

@testable import Insights

/// `POST /api/resources/{id}/collect`, the console's **Collect now**.
///
/// The route must behave like one resource's share of the hourly sweep: the same job, the same
/// retry budget, and the same lease booked after dispatch. Where it cannot queue a real
/// collection, it has to refuse rather than answer 202, because nothing else would tell the
/// administrator that no job is coming.
@Suite("Collect Now", .serialized)
struct CollectNowControllerTests {
  private func past(_ days: Int) -> Date {
    Date().addingTimeInterval(Double(-days) * 86_400)
  }

  private func path(_ resource: Resource) throws -> String {
    "api/resources/\(try resource.requireID())/collect"
  }

  /// Asserts the resource was booked one cadence from roughly now: the sweep's lease, not the
  /// success booking a finished job writes.
  private func expectLeaseBooked(
    _ resource: Resource,
    on db: any Database,
    from start: Date,
  ) async throws {
    let booked = try #require(try await Resource.find(resource.id, on: db)?.nextCollectionAt)
    let interval = Double(resource.collectionIntervalDays) * 86_400
    #expect(booked >= start.addingTimeInterval(interval - 1))
    #expect(booked <= Date().addingTimeInterval(interval + 1))
  }

  @Test
  func `Refuses an anonymous caller`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        try path(resource),
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  @Test
  func `Refuses a signed-in non-admin`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.userAuth,
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  @Test
  func `Queues a GitHub repository and books its lease`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        type: .repository,
        nextCollectionAt: past(1),
      )
      let start = Date()

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .accepted)
          let returned = try res.content.decode(Resource.Public.self)
          #expect(returned.id == resource.id)
          // The response carries the new lease, so the console's row updates without guessing.
          #expect(try #require(returned.nextCollectionAt) > Date())
        },
      )

      #expect(
        app.queues.asyncTest.all(SyncGitHubRepoStats.self).map(\.id) == [try resource.requireID()])
      // The sweep's budget, not a shorter one. A job an administrator starts rides out a throttle
      // exactly as a scheduled one does, and an exhausted failure re-books the same way.
      #expect(
        app.queues.asyncTest.jobs.values.allSatisfy { $0.maxRetryCount == syncJobMaxRetryCount })
      try await expectLeaseBooked(resource, on: app.db, from: start)
    }
  }

  /// GHCR has a collector now. It sat in the dispatcher's skip branch until `SyncGHCRStats`
  /// shipped, so this pins that the route treats it like any other collected platform.
  @Test
  func `Queues a GHCR container and books its lease`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .ghcr)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        type: .container,
        collectionIntervalDays: 30,
      )
      let start = Date()

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .accepted)
        },
      )

      #expect(
        app.queues.asyncTest.all(SyncGHCRStats.self).map(\.id) == [try resource.requireID()])
      try await expectLeaseBooked(resource, on: app.db, from: start)
    }
  }

  /// The reason the lease is booked at all. Without it an overdue resource stays due, and the
  /// next hourly sweep queues a second job while the first is still running.
  @Test
  func `The lease keeps the next sweep from queuing it again`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(
        on: app.db,
        accountID: try account.requireID(),
        type: .repository,
        nextCollectionAt: past(1),
      )

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .accepted)
        },
      )
      try await CollectDueResources().run(context: queueContext(for: app))

      #expect(app.queues.asyncTest.all(SyncGitHubRepoStats.self).count == 1)
    }
  }

  /// The dispatcher skips these without an error, which is right for a sweep. A request that
  /// did the same would answer 202 for a job that was never queued.
  @Test(arguments: [Platform.npm, .pypi])
  func `Refuses a platform that is not collected`(platform: Platform) async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: platform)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), type: .package)

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .conflict)
          #expect(res.body.string.contains("Resources on \(platform.rawValue) are not collected"))
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
      // Left unscheduled, as npm and PyPI rows are meant to be.
      #expect(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt == nil)
    }
  }

  /// The job would skip an orphan and write nothing. The due date stays too, as the sweep leaves
  /// it, so a restored account resumes on the next sweep.
  @Test
  func `Refuses a resource whose account is deleted`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let due = past(1)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), nextCollectionAt: due)
      try await account.delete(on: app.db)

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .conflict)
          #expect(res.body.string.contains("account has been deleted"))
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
      let kept = try #require(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(kept.timeIntervalSince(due)) < 1)
    }
  }

  /// What keeps the route and the dispatcher agreeing. Every platform the route accepts must reach
  /// a job, and every platform it refuses must be one the dispatcher skips. Iterating `allCases`
  /// means a new platform is checked without anyone remembering to add it here.
  @Test(arguments: Platform.allCases)
  func `The dispatcher queues a job exactly when the platform has a collector`(
    platform: Platform
  ) async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: platform)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.queues.queue(.metrics).dispatchSync(
        for: resource, platform: platform, logger: app.logger)

      #expect(app.queues.asyncTest.queue.count == (platform.hasCollector ? 1 : 0))
    }
  }

  @Test
  func `Returns not found for an unknown resource`() async throws {
    try await withQueueApp { app in
      try await app.testing().test(
        .POST,
        "api/resources/\(UUID())/collect",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .notFound)
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  /// A deleted resource is gone from the catalog, so it answers like one that never existed.
  @Test
  func `Returns not found for a deleted resource`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      try await resource.delete(on: app.db)

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .notFound)
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  /// Valkey refusing the job. The lease is booked only after a dispatch succeeds, so the due
  /// date must be exactly what it was: booking it here would push the resource a cadence out
  /// for a collection that was never queued.
  @Test
  func `A refused dispatch answers 503 and books nothing`() async throws {
    let driver = FlakyQueuesDriver()
    try await withInsightsApp(setUp: { $0.queues.use(custom: driver) }) { app in
      let account = try await makeAccount(on: app.db)
      let due = past(1)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), nextCollectionAt: due)

      try await app.testing().test(
        .POST,
        try path(resource),
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .serviceUnavailable)
        },
      )

      #expect(driver.stored.withLockedValue { $0.isEmpty })
      let kept = try #require(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(kept.timeIntervalSince(due)) < 1)
    }
  }
}
