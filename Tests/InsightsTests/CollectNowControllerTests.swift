import Fluent
import Queues
import Testing
import VaporTesting
import XCTQueues

@testable import Insights

/// The administrator-facing "collect now" trigger.
///
/// Exists so an operator who has just repaired a credential or shipped a collector fix can find
/// out whether it worked, instead of waiting on the hourly sweep — or, for a non-credential
/// failure, on a due date the sweep already advanced a full cadence.
@Suite("Collect Now", .serialized)
struct CollectNowControllerTests {
  @Test
  func `Dispatches a sync for a collectable resource`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources/\(try resource.requireID())/collect",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .accepted)
          let dispatch = try res.content.decode(Resource.CollectionDispatch.self)
          #expect(dispatch.resourceID == resource.id)
        },
      )

      #expect(
        app.queues.asyncTest.all(SyncGitHubRepoStats.self).map(\.id) == [try resource.requireID()])
    }
  }

  /// A manual run is a question — "does it work now?" — and the answer has to arrive while the
  /// operator is still watching. The scheduled budget spends about ten and a half minutes across
  /// its backoff before reporting, which is the right trade for an unattended sweep riding out a
  /// throttle, and the wrong one here.
  @Test
  func `Dispatches with no retry budget so the verdict is immediate`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources/\(try resource.requireID())/collect",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .accepted)
        },
      )

      #expect(app.queues.asyncTest.jobs.values.allSatisfy { $0.maxRetryCount == 0 })
    }
  }

  /// The sweep skips these silently and correctly — they are catalogued, just not collectable.
  /// A button cannot: a 202 that enqueues nothing leaves the caller polling for a verdict that
  /// will never arrive.
  @Test
  func `Refuses a platform with no collector instead of accepting silently`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db, name: "insights", platform: .npm)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), type: .package)

      try await app.testing().test(
        .POST,
        "api/resources/\(try resource.requireID())/collect",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .unprocessableEntity)
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
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
    }
  }

  @Test
  func `Refuses a signed-in non-admin`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources/\(try resource.requireID())/collect",
        headers: app.userAuth,
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
        },
      )

      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  /// Scheduling state is deliberately untouched. The endpoint returns before the job runs, so the
  /// only thing it could do is advance the due date without knowing the outcome — which would bury
  /// a broken resource a further cadence out on every click, the exact opposite of what the button
  /// is for.
  @Test
  func `Leaves the collection schedule alone`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let due = Date(timeIntervalSince1970: 1_780_000_000)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), nextCollectionAt: due)

      try await app.testing().test(
        .POST,
        "api/resources/\(try resource.requireID())/collect",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .accepted)
        },
      )

      let reloaded = try #require(try await Resource.find(try resource.requireID(), on: app.db))
      #expect(reloaded.nextCollectionAt == due)
    }
  }
}
