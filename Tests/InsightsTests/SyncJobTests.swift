import Fluent
import Foundation
import Queues
import Testing
import Vapor

@testable import Insights

/// The sync jobs are what actually writes metrics, and every one of their failure modes is a
/// thrown `JobError` the worker only logs. These drive each path against a stubbed client so
/// nothing here depends on a live GitHub, Hub, or Tapis.
@Suite("Sync jobs", .serialized)
struct SyncJobTests {
  // MARK: - Helpers

  /// `Metric.foldDailyIntoAllTime` reads the real clock through the job, so traffic days have
  /// to be generated relative to now — a hard-coded date drifts out of the window and stops
  /// being folded at all.
  private func trafficJSON(
    key: String,
    rolling: Int,
    days: [(offset: Int, count: Int)],
  ) -> String {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = utc.startOfDay(for: Date())

    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    let entries = days.map { day in
      let stamp = formatter.string(from: midnight.addingTimeInterval(Double(day.offset) * 86_400))
      return #"{"timestamp": "\#(stamp)", "count": \#(day.count), "uniques": \#(day.count)}"#
    }

    return """
      {"count": \(rolling), "uniques": \(rolling), "\(key)": [\(entries.joined(separator: ","))]}
      """
  }

  /// The error a job threw, or nil if it succeeded. `JobError` is not `Equatable`, so callers
  /// pattern-match the case they expect.
  private func thrownJobError(_ body: () async throws -> Void) async -> JobError? {
    do {
      try await body()
      return nil
    } catch {
      return error as? JobError
    }
  }

  private func readings(on db: any Database, _ resourceID: Resource.IDValue) async throws
    -> [MetricType: Double]
  {
    try await Metric.query(on: db)
      .filter(\.$resource.$id == resourceID)
      .all()
      .reduce(into: [:]) { $0[$1.type] = $1.reading }
  }

  /// A GitHub account with a vault and one repository, which is what every repo sweep needs
  /// before it can reach the network.
  private func makeGitHubRepo(on app: Application) async throws -> Resource {
    let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
    let accountID = try account.requireID()
    _ = try await makeVault(on: app.db, accountID: accountID)
    return try await makeResource(
      on: app.db, accountID: accountID, name: "insights", type: .repository)
  }

  // MARK: - SyncGitHubRepoStats

  @Test
  func `A sweep records gauges and folds only completed traffic days`() async throws {
    try await withApp { app in
      let resource = try await makeGitHubRepo(on: app)
      let id = try resource.requireID()

      stubAPI(
        on: app,
        [
          .ok(
            "/repos/icicle-ai/insights",
            #"{"stargazers_count": 12, "forks_count": 3, "subscribers_count": 5}"#),
          // Today's 100 clones are still accruing and must stay out of the all-time total.
          .ok(
            "/repos/icicle-ai/insights/traffic/clones",
            trafficJSON(
              key: "clones", rolling: 112,
              days: [(-2, 5), (-1, 7), (0, 100)])),
          .ok(
            "/repos/icicle-ai/insights/traffic/views",
            trafficJSON(key: "views", rolling: 23, days: [(-1, 20), (0, 3)])),
        ])

      try await SyncGitHubRepoStats().dequeue(queueContext(for: app), .init(id: id))

      let readings = try await readings(on: app.db, id)
      // Gauges are stored as reported; the traffic rows keep the rolling window, which is the
      // repository's current reach rather than a delta.
      #expect(readings[.stars] == 12)
      #expect(readings[.forks] == 3)
      #expect(readings[.subscribers] == 5)
      #expect(readings[.clones] == 112)
      #expect(readings[.views] == 23)
      // Only the completed days: 5 + 7, and 20.
      #expect(readings[.clonesAllTime] == 12)
      #expect(readings[.viewsAllTime] == 20)

      let watermarks = try await MetricWatermark.query(on: app.db)
        .filter(\.$resource.$id == id)
        .all()
        .map(\.type)
        .sorted { $0.rawValue < $1.rawValue }
      #expect(watermarks == [.clones, .views])
    }
  }

  /// The regression the watermark exists for: GitHub hands back the same rolling window on the
  /// next sweep, and folding it whole would re-add every shared day.
  @Test
  func `Re-running a sweep adds readings but not a double-counted total`() async throws {
    try await withApp { app in
      let resource = try await makeGitHubRepo(on: app)
      let id = try resource.requireID()

      stubAPI(
        on: app,
        [
          .ok(
            "/repos/icicle-ai/insights",
            #"{"stargazers_count": 12, "forks_count": 3, "subscribers_count": 5}"#),
          .ok(
            "/repos/icicle-ai/insights/traffic/clones",
            trafficJSON(key: "clones", rolling: 112, days: [(-2, 5), (-1, 7)])),
          .ok(
            "/repos/icicle-ai/insights/traffic/views",
            trafficJSON(key: "views", rolling: 23, days: [(-1, 20)])),
        ])

      let job = SyncGitHubRepoStats()
      try await job.dequeue(queueContext(for: app), .init(id: id))
      try await job.dequeue(queueContext(for: app), .init(id: id))

      // Each sweep appends its own reading — that series is the point — but the totals hold.
      let series = try await Metric.query(on: app.db)
        .filter(\.$resource.$id == id)
        .filter(\.$type ~~ [.stars, .forks, .subscribers, .clones, .views])
        .count()
      #expect(series == 10)

      let readings = try await readings(on: app.db, id)
      #expect(readings[.clonesAllTime] == 12)
      #expect(readings[.viewsAllTime] == 20)
    }
  }

  @Test
  func `A sweep for a missing resource fails with entryNotFound`() async throws {
    try await withApp { app in
      stubAPI(on: app, [])

      let error = await thrownJobError {
        try await SyncGitHubRepoStats().dequeue(queueContext(for: app), .init(id: UUID()))
      }

      guard case .entryNotFound? = error else {
        Issue.record("expected entryNotFound, got \(String(describing: error?.description))")
        return
      }
    }
  }

  @Test
  func `A sweep for an account without a vault fails with missingToken`() async throws {
    try await withApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "insights", type: .repository)
      stubAPI(on: app, [])

      let error = await thrownJobError {
        try await SyncGitHubRepoStats()
          .dequeue(queueContext(for: app), .init(id: try resource.requireID()))
      }

      guard case .missingToken? = error else {
        Issue.record("expected missingToken, got \(String(describing: error?.description))")
        return
      }
    }
  }

  /// Every fetch completes before anything is written, so a failure partway through leaves no
  /// half-swept resource — gauges without the traffic rows that share their timestamp.
  @Test
  func `A failed traffic fetch writes no metrics at all`() async throws {
    try await withApp { app in
      let resource = try await makeGitHubRepo(on: app)
      let id = try resource.requireID()

      stubAPI(
        on: app,
        [
          .ok(
            "/repos/icicle-ai/insights",
            #"{"stargazers_count": 12, "forks_count": 3, "subscribers_count": 5}"#),
          .failing("/repos/icicle-ai/insights/traffic/clones", .forbidden),
        ])

      let error = await thrownJobError {
        try await SyncGitHubRepoStats().dequeue(queueContext(for: app), .init(id: id))
      }

      guard case .apiRequestFailed(_, let statusCode, _)? = error else {
        Issue.record("expected apiRequestFailed, got \(String(describing: error?.description))")
        return
      }
      #expect(statusCode == 403)
      #expect(try await Metric.query(on: app.db).count() == 0)
    }
  }

  @Test
  func `A malformed body fails with decodingFailed`() async throws {
    try await withApp { app in
      let resource = try await makeGitHubRepo(on: app)

      stubAPI(on: app, [.malformed("/repos/icicle-ai/insights")])

      let error = await thrownJobError {
        try await SyncGitHubRepoStats()
          .dequeue(queueContext(for: app), .init(id: try resource.requireID()))
      }

      guard case .decodingFailed? = error else {
        Issue.record("expected decodingFailed, got \(String(describing: error?.description))")
        return
      }
    }
  }

  // MARK: - SyncHuggingFaceHubStats

  @Test
  func `A Hub sweep stores the rolling window and snapshots the lifetime total`() async throws {
    try await withApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID, name: "huggingface-token")
      let resource = try await makeResource(
        on: app.db, accountID: accountID, name: "insights", type: .model)
      let id = try resource.requireID()

      stubAPI(
        on: app,
        [
          .ok(
            "/api/models/icicle/insights",
            #"{"downloads": 500, "downloadsAllTime": 12000, "likes": 7}"#)
        ])

      try await SyncHuggingFaceHubStats().dequeue(queueContext(for: app), .init(id: id))

      let first = try await readings(on: app.db, id)
      #expect(first[.downloads] == 500)
      #expect(first[.likes] == 7)
      #expect(first[.downloadsAllTime] == 12000)

      // A second sweep replaces the lifetime figure rather than compounding it, which is what
      // accumulating the rolling 30-day `downloads` would have done.
      stubAPI(
        on: app,
        [
          .ok(
            "/api/models/icicle/insights",
            #"{"downloads": 400, "downloadsAllTime": 12500, "likes": 9}"#)
        ])
      try await SyncHuggingFaceHubStats().dequeue(queueContext(for: app), .init(id: id))

      let totals = try await Metric.query(on: app.db)
        .filter(\.$resource.$id == id)
        .filter(\.$type == .downloadsAllTime)
        .all()
      #expect(totals.count == 1)
      #expect(totals.first?.reading == 12500)

      let second = try await readings(on: app.db, id)
      #expect(second[.likes] == 9)
    }
  }

  /// `expand[]` is a whitelist, not an addition: the response carries only what is named, so a
  /// dropped parameter removes the field silently rather than erroring. The segment split is
  /// the Hub's, not ours — datasets and models live under different roots.
  @Test
  func `Each repo kind is fetched from its own segment with every expanded field`() async throws {
    try await withApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID, name: "huggingface-token")
      let model = try await makeResource(
        on: app.db, accountID: accountID, name: "insights", type: .model)
      let dataset = try await makeResource(
        on: app.db, accountID: accountID, name: "corpus", type: .dataset)

      let body = #"{"downloads": 1, "downloadsAllTime": 2, "likes": 3}"#
      let requests = stubAPI(
        on: app,
        [
          .ok("/api/models/icicle/insights", body),
          .ok("/api/datasets/icicle/corpus", body),
        ])

      let job = SyncHuggingFaceHubStats()
      try await job.dequeue(queueContext(for: app), .init(id: try model.requireID()))
      try await job.dequeue(queueContext(for: app), .init(id: try dataset.requireID()))

      let hubURLs = requests.withLockedValue { $0.map(\.url.string) }
        .filter { $0.contains("huggingface.co") }
      #expect(hubURLs.count == 2)

      for url in hubURLs {
        #expect(url.contains("expand[]=downloads"))
        #expect(url.contains("expand[]=downloadsAllTime"))
        #expect(url.contains("expand[]=likes"))
      }
      #expect(hubURLs.contains { $0.contains("/api/models/icicle/insights") })
      #expect(hubURLs.contains { $0.contains("/api/datasets/icicle/corpus") })
    }
  }

  // MARK: - SyncGitHubOrgStats

  @Test
  func `Org followers are written back from the plural orgs endpoint`() async throws {
    try await withApp { app in
      let account = try await makeAccount(
        on: app.db, name: "icicle-ai", platform: .github, followers: 10)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID)

      // `/org/{org}` — singular — 404s. Recording the URL is what pins the spelling.
      let requests = stubAPI(on: app, [.ok("/orgs/icicle-ai", #"{"followers": 42}"#)])

      try await SyncGitHubOrgStats().dequeue(queueContext(for: app), .init(id: accountID))

      #expect(try await Account.find(accountID, on: app.db)?.followers == 42)
      let paths = requests.withLockedValue { $0.map(\.url.path) }
      #expect(paths.contains("/orgs/icicle-ai"))
    }
  }

  @Test
  func `An unchanged follower count leaves the account untouched`() async throws {
    try await withApp { app in
      let account = try await makeAccount(
        on: app.db, name: "icicle-ai", platform: .github, followers: 42)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID)
      let before = try #require(try await Account.find(accountID, on: app.db)?.updatedAt)

      stubAPI(on: app, [.ok("/orgs/icicle-ai", #"{"followers": 42}"#)])

      try await SyncGitHubOrgStats().dequeue(queueContext(for: app), .init(id: accountID))

      // An unconditional save would bump `updatedAt` on every daily sweep, making the column
      // useless for spotting accounts that actually moved.
      let after = try #require(try await Account.find(accountID, on: app.db)?.updatedAt)
      #expect(before == after)
    }
  }
}
