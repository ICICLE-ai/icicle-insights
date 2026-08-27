import Fluent
import Foundation
import NIOConcurrencyHelpers
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
    try await withInsightsApp { app in
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
    try await withInsightsApp { app in
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
  func `A sweep for a missing resource is a no-op rather than a retried failure`() async throws {
    try await withInsightsApp { app in
      let requests = stubAPI(on: app, [])

      // Throwing here would be retried four times across roughly ten minutes, because
      // `QueueWorker` decides from the remaining attempt count alone and the budget is fixed at
      // dispatch. A deleted row will not reappear, so the job completes instead.
      try await SyncGitHubRepoStats().dequeue(queueContext(for: app), .init(id: UUID()))

      // And it stops before spending a request on a resource it cannot describe.
      #expect(requests.withLockedValue { $0 }.isEmpty)
    }
  }

  @Test
  func `A sweep for a missing account is a no-op`() async throws {
    try await withInsightsApp { app in
      let requests = stubAPI(on: app, [])

      try await SyncGitHubOrgStats().dequeue(queueContext(for: app), .init(id: UUID()))

      #expect(requests.withLockedValue { $0 }.isEmpty)
    }
  }

  @Test
  func `A sweep for an account without a vault fails with missingToken`() async throws {
    try await withInsightsApp { app in
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
    try await withInsightsApp { app in
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

      // Only the happy path anchors the schedule on success — a failed sweep, even one that
      // wrote nothing, must not be mistaken for a collection.
      let reloaded = try #require(try await Resource.find(id, on: app.db))
      #expect(reloaded.lastCollectedAt == nil)
    }
  }

  @Test
  func `A malformed body fails with decodingFailed`() async throws {
    try await withInsightsApp { app in
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
    try await withInsightsApp { app in
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

      // The Hub collector carries the identical `recordSuccessfulCollection` call as GitHub's,
      // but nothing else drives it through `dequeue` — this is the only place it is proven.
      let reloaded = try #require(try await Resource.find(id, on: app.db))
      #expect(reloaded.lastCollectedAt != nil)
      #expect(reloaded.stallNotifiedAt == nil)
    }
  }

  /// `expand[]` is a whitelist, not an addition: the response carries only what is named, so a
  /// dropped parameter removes the field silently rather than erroring. The segment split is
  /// the Hub's, not ours — datasets and models live under different roots.
  @Test
  func `Each repo kind is fetched from its own segment with every expanded field`() async throws {
    try await withInsightsApp { app in
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

      // Compared against the percent-decoded query rather than the raw string: Vapor encodes the
      // brackets as `%5B%5D`, which Hugging Face decodes back to `expand[]` and answers normally.
      // Asserting on the literal brackets tests Vapor's encoding choice rather than the field set
      // this job actually asks for, and fails without anything being wrong.
      for url in hubURLs {
        let decoded = url.removingPercentEncoding ?? url
        #expect(decoded.contains("expand[]=downloads"))
        #expect(decoded.contains("expand[]=downloadsAllTime"))
        #expect(decoded.contains("expand[]=likes"))
      }
      #expect(hubURLs.contains { $0.contains("/api/models/icicle/insights") })
      #expect(hubURLs.contains { $0.contains("/api/datasets/icicle/corpus") })
    }
  }

  // MARK: - SyncGitHubOrgStats

  @Test
  func `Org followers are written back from the plural orgs endpoint`() async throws {
    try await withInsightsApp { app in
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
    try await withInsightsApp { app in
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

  // MARK: - SyncPatraCatalog

  /// A JSON body wrapped in a `ClientResponse`. Duplicated rather than shared: `TestSupport.swift`
  /// and `PatraAPITests.swift` each keep their own file-private copy of the same helper, for the
  /// same reason — neither is visible outside its own file.
  private func jsonResponse(_ status: HTTPResponseStatus, _ body: String) -> ClientResponse {
    ClientResponse(
      status: status,
      headers: ["Content-Type": "application/json"],
      body: ByteBuffer(string: body),
    )
  }

  /// Answers `/modelcards` and `/datasheets` from fixed bodies, for tests whose whole catalog
  /// fits on one page. `stubPagedAPI`, not `stubAPI`: `PatraAPI.page` always asks with a query
  /// string, which `stubAPI`'s path-only matching cannot see.
  ///
  /// Every public model card in `modelCards` now costs a `GET /modelcard/{uuid}` detail request
  /// too — that is what this task adds — so this stub answers those as well, from `details`
  /// (keyed by uuid) when a test cares about the provenance in the response, and with an empty,
  /// no-location body otherwise. Without that default, every test written before this task that
  /// registers a public model card would 404 on a request it never anticipated.
  @discardableResult
  private func stubPatraCatalog(
    on app: Application,
    modelCards: String = "[]",
    datasheets: String = "[]",
    details: [String: String] = [:]
  ) -> NIOLockedValueBox<[ClientRequest]> {
    stubPagedAPI(on: app) { url in
      if url.contains("/modelcards"), url.contains("skip=0") {
        return self.jsonResponse(.ok, modelCards)
      }
      if url.contains("/datasheets"), url.contains("skip=0") {
        return self.jsonResponse(.ok, datasheets)
      }
      if url.hasPrefix("\(PatraAPI.baseURL)/modelcard/") {
        let uuid = String(url.dropFirst("\(PatraAPI.baseURL)/modelcard/".count))
        return self.jsonResponse(.ok, details[uuid] ?? self.emptyDetailJSON)
      }
      return nil
    }
  }

  /// A `/modelcard/{uuid}` detail response naming no `ai_model` and no training datasheet — the
  /// default for any test that registers a public model card without asserting on its provenance.
  private var emptyDetailJSON: String {
    #"{"ai_model":null,"training_datasheet_uuid":null}"#
  }

  /// A `/modelcard/{uuid}` detail response carrying a specific location and/or datasheet link.
  private func detailJSON(location: String? = nil, trainingDatasheetUUID: String? = nil) -> String {
    let locationJSON = location.map { #""\#($0)""# } ?? "null"
    let datasheetJSON = trainingDatasheetUUID.map { #""\#($0)""# } ?? "null"
    return
      #"{"ai_model":{"location":\#(locationJSON)},"training_datasheet_uuid":\#(datasheetJSON)}"#
  }

  /// A Patra account with no vault: collection here is deliberately anonymous, so none of these
  /// tests should ever see a vault lookup happen.
  private func makePatraAccount(on app: Application, name: String = "icicleai") async throws
    -> Account
  {
    try await makeAccount(on: app.db, name: name, platform: .patra)
  }

  /// One `PatraModelCard` JSON object. `is_private` and `version` are always present, matching
  /// what the live endpoint sends — Patra reports `false` rather than omitting the key.
  private func modelCardJSON(
    uuid: String, name: String, version: String? = "1.0", isPrivate: Bool = false
  ) -> String {
    let versionJSON = version.map { "\"\($0)\"" } ?? "null"
    return
      #"{"uuid":"\#(uuid)","name":"\#(name)","version":\#(versionJSON),"is_private":\#(isPrivate)}"#
  }

  /// Re-running the sync is the reason `patra_cards.card_uuid` is a unique column: nothing else
  /// about a card is stable enough to key off. This drives the whole discovery job — model cards
  /// grouped by name, a datasheet on its own — through two identical sweeps and checks that the
  /// second finds nothing new to do.
  @Test
  func `Re-running the catalog sync adds nothing`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      let modelCards = [
        modelCardJSON(uuid: "alpha-1", name: "Alpha", version: "1.0"),
        modelCardJSON(uuid: "alpha-2", name: "Alpha", version: "2.0"),
        modelCardJSON(uuid: "beta-1", name: "Beta", version: "1.0"),
      ].joined(separator: ",")
      let datasheets = [
        #"{"uuid":"gamma-1","title":"Gamma","version":null,"is_private":false}"#,
        #"{"uuid":"delta-1","title":"Delta","version":null,"is_private":false}"#,
      ].joined(separator: ",")
      stubPatraCatalog(on: app, modelCards: "[\(modelCards)]", datasheets: "[\(datasheets)]")

      let job = SyncPatraCatalog()
      try await job.dequeue(queueContext(for: app), .init(id: try account.requireID()))

      // Two model resources (Alpha, Beta) plus two dataset resources (Gamma, Delta); five cards
      // total — Alpha carries two.
      #expect(try await Resource.query(on: app.db).count() == 4)
      #expect(try await PatraCard.query(on: app.db).count() == 5)

      try await job.dequeue(queueContext(for: app), .init(id: try account.requireID()))

      #expect(try await Resource.query(on: app.db).count() == 4)
      #expect(try await PatraCard.query(on: app.db).count() == 5)
    }
  }

  /// The domain fact the whole job is built around: a Patra "model card" is a (name, version)
  /// pair, not a distinct model. Eleven cards under one name, mirroring the real
  /// `MegaDetector for Wildlife Detection`, must collapse to one `Resource` carrying all eleven
  /// `PatraCard` rows rather than eleven resources.
  @Test
  func `Cards sharing a model name collapse into one resource`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      let cards = (0..<11)
        .map { modelCardJSON(uuid: "mega-\($0)", name: "MegaDetector", version: "v\($0)") }
        .joined(separator: ",")
      stubPatraCatalog(on: app, modelCards: "[\(cards)]")

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let resources = try await Resource.query(on: app.db).filter(\.$type == .model).all()
      #expect(resources.count == 1)
      let resource = try #require(resources.first)
      #expect(resource.name == "MegaDetector")

      let cardRows = try await PatraCard.query(on: app.db)
        .filter(\.$resource.$id == (try resource.requireID()))
        .all()
      #expect(cardRows.count == 11)
    }
  }

  /// `PatraAPI.page` always asks for `limit=100`, so a catalog only pages when it exceeds that —
  /// the boundary this test crosses with 105 cards split into a 100-entry first page and a
  /// 5-entry second. All eleven distinct names must register, including the ones that only ever
  /// appear on the second HTTP response, proving the job consumes everything `page` hands back
  /// rather than only the first request's batch.
  @Test
  func `Every card registers even when the catalog spans two pages`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      let firstPage = (0..<100)
        .map { modelCardJSON(uuid: "model-\($0)", name: "Model \($0)") }
        .joined(separator: ",")
      let secondPage = (100..<105)
        .map { modelCardJSON(uuid: "model-\($0)", name: "Model \($0)") }
        .joined(separator: ",")

      let requests = stubPagedAPI(on: app) { url in
        // Every one of the 105 public cards costs its own `/modelcard/{uuid}` detail request
        // once the list fetch above has landed — answered with no location, since this test is
        // about pagination, not provenance.
        if url.hasPrefix("\(PatraAPI.baseURL)/modelcard/") {
          return self.jsonResponse(.ok, self.emptyDetailJSON)
        }
        guard url.contains("/modelcards") || url.contains("/datasheets") else { return nil }
        if url.contains("/datasheets") { return self.jsonResponse(.ok, "[]") }
        if url.contains("skip=0") { return self.jsonResponse(.ok, "[\(firstPage)]") }
        if url.contains("skip=100") { return self.jsonResponse(.ok, "[\(secondPage)]") }
        return nil
      }

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      #expect(try await Resource.query(on: app.db).filter(\.$type == .model).count() == 105)
      #expect(try await PatraCard.query(on: app.db).count() == 105)
      // Specifically a card that only ever appeared on the second page — the regression a loop
      // that quietly drops later pages would produce.
      let secondPageCard = try await PatraCard.query(on: app.db)
        .filter(\.$cardUUID == "model-104")
        .first()
      #expect(secondPageCard != nil)

      let modelcardRequests = requests.withLockedValue { $0.map(\.url.string) }
        .filter { $0.contains("/modelcards") }
      #expect(modelcardRequests.count == 2)
    }
  }

  /// Fetch everything, then write everything — across both catalogs, not just within one page
  /// loop. `/modelcards` succeeds and would, on its own, register a resource; `/datasheets` then
  /// fails. If the job wrote model cards before requesting datasheets, this would land a
  /// half-registry: model resources persisted, no datasets, until a backoff-delayed retry. The
  /// fix is fetching both lists before writing either, so a later failure leaves nothing written
  /// at all.
  @Test
  func `A failed datasheets fetch writes no catalog rows at all`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)

      let requests = stubPagedAPI(on: app) { url in
        if url.contains("/modelcards"), url.contains("skip=0") {
          return self.jsonResponse(
            .ok, "[\(self.modelCardJSON(uuid: "would-land", name: "Would Land"))]")
        }
        if url.contains("/datasheets") {
          return self.jsonResponse(.internalServerError, #"{"detail":"boom"}"#)
        }
        return nil
      }

      let error = await thrownJobError {
        try await SyncPatraCatalog().dequeue(
          queueContext(for: app), .init(id: try account.requireID()))
      }

      guard case .apiRequestFailed? = error else {
        Issue.record("expected apiRequestFailed, got \(String(describing: error?.description))")
        return
      }

      // Nothing from the model half landed either, even though it fetched and would have
      // registered cleanly on its own.
      #expect(try await Resource.query(on: app.db).count() == 0)
      #expect(try await PatraCard.query(on: app.db).count() == 0)

      let paths = requests.withLockedValue { $0.map(\.url.path) }
      #expect(paths.contains("/modelcards"))
      #expect(paths.contains("/datasheets"))
    }
  }

  /// `is_private == true` skips the card entirely — no `Resource`, no `PatraCard` — rather than
  /// registering it and hiding it later. A public dashboard has no business creating a row for
  /// something the registry says is private.
  @Test
  func `A private card is skipped entirely`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "secret-1", name: "Secret Model", isPrivate: true))]")

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      #expect(try await Resource.query(on: app.db).count() == 0)
      #expect(try await PatraCard.query(on: app.db).count() == 0)
    }
  }

  /// An admin soft-deleting a resource means "stop tracking this." A new card arriving under
  /// that resource's old name must not resurrect it, and must not create a second resource with
  /// the same name either — the (name, account_id, type) unique index would reject that anyway,
  /// but the correct behaviour is to skip the card, not to fail the sweep.
  @Test
  func `A card whose resource is soft-deleted is not resurrected`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      let accountID = try account.requireID()
      let deleted = try await makeResource(
        on: app.db, accountID: accountID, name: "Retired Model", type: .model)
      try await deleted.delete(on: app.db)

      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "new-card-1", name: "Retired Model"))]")

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: accountID))

      #expect(try await PatraCard.query(on: app.db).count() == 0)
      // Still exactly the one, still soft-deleted — not resurrected and not duplicated.
      let all = try await Resource.query(on: app.db).withDeleted().all()
      #expect(all.count == 1)
      #expect(all.first?.deletedAt != nil)
    }
  }

  /// `Yield Estimation` is the live catalog's example of a card with no `version`. `nil` must
  /// round-trip as `nil`, not as an empty string or a decoding failure.
  @Test
  func `A null version is stored as null`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards:
          "[\(modelCardJSON(uuid: "yield-1", name: "Yield Estimation", version: nil))]")

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "yield-1").first())
      #expect(card.version == nil)
    }
  }

  /// A known `card_uuid` arriving under a changed name is logged, not applied: renaming the
  /// resource would be wrong when it already groups cards from other authors, and would orphan
  /// its metric history against a name nobody recognizes. The attachment — and the name — must
  /// hold, and no duplicate resource or card may appear.
  @Test
  func `A known uuid under a changed name keeps its old attachment`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      let accountID = try account.requireID()

      stubPatraCatalog(
        on: app, modelCards: "[\(modelCardJSON(uuid: "stable-uuid", name: "Old Name"))]")
      let job = SyncPatraCatalog()
      try await job.dequeue(queueContext(for: app), .init(id: accountID))

      let firstResource = try #require(
        try await Resource.query(on: app.db).filter(\.$type == .model).first())
      #expect(firstResource.name == "Old Name")

      stubPatraCatalog(
        on: app, modelCards: "[\(modelCardJSON(uuid: "stable-uuid", name: "New Name"))]")
      try await job.dequeue(queueContext(for: app), .init(id: accountID))

      #expect(try await Resource.query(on: app.db).count() == 1)
      #expect(try await PatraCard.query(on: app.db).count() == 1)
      let reloaded = try #require(try await Resource.find(firstResource.id, on: app.db))
      #expect(reloaded.name == "Old Name")
    }
  }

  /// A datasheet is keyed by `title`, not `name` — the field Patra's `/datasheets` endpoint
  /// actually sends — and becomes a `.dataset` resource, distinct from a `.model` even if a
  /// title happened to collide with a model name (the unique index is scoped by `type`).
  @Test
  func `A datasheet becomes a dataset resource named after its title`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        datasheets:
          #"[{"uuid":"sheet-1","title":"Camera Trap Corpus","version":null,"is_private":false}]"#
      )

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let resource = try #require(
        try await Resource.query(on: app.db).filter(\.$type == .dataset).first())
      #expect(resource.name == "Camera Trap Corpus")

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "sheet-1").first())
      #expect(try card.$resource.id == resource.requireID())
    }
  }

  /// The row `configure.swift` and `SyncDispatch.swift` are not yet asked to build: no vault, no
  /// token header, ever. This is what "Patra is anonymous" actually means at the network layer —
  /// `stubPatraCatalog` would 404 on a vault-secret path the job never has reason to request, so
  /// a job that started sending one would fail loudly here rather than silently leaking a token.
  @Test
  func `A sweep for a missing Patra account is a no-op`() async throws {
    try await withInsightsApp { app in
      let requests = stubPatraCatalog(on: app)

      try await SyncPatraCatalog().dequeue(queueContext(for: app), .init(id: UUID()))

      #expect(requests.withLockedValue { $0 }.isEmpty)
    }
  }

  // MARK: - SyncPatraCatalog / provenance resolution

  /// A `huggingface.co` location whose first two path components — owner, then model name —
  /// match a registered resource under a Hugging Face account lands in `hubResource`, and
  /// `sourceURL` holds the raw location regardless.
  @Test
  func `A huggingface_co location resolves into hubResource`() async throws {
    try await withInsightsApp { app in
      let hfAccount = try await makeAccount(on: app.db, name: "acme", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "vision-model", type: .model)

      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "hf-1", name: "Vision Model"))]",
        details: [
          "hf-1": detailJSON(location: "https://huggingface.co/acme/vision-model")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "hf-1").first())
      #expect(card.sourceURL == "https://huggingface.co/acme/vision-model")
      #expect(try card.$hubResource.id == hubResource.requireID())
      #expect(card.$repositoryResource.id == nil)
    }
  }

  /// A `github.com` location resolves the same way, into `repositoryResource` instead — the
  /// trailing path beyond owner/repo (`/raw/main/model.pt`) is ignored.
  @Test
  func `A github_com location resolves into repositoryResource`() async throws {
    try await withInsightsApp { app in
      let ghAccount = try await makeAccount(on: app.db, name: "acme", platform: .github)
      let repoResource = try await makeResource(
        on: app.db, accountID: try ghAccount.requireID(), name: "vision-model-src",
        type: .repository)

      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "gh-1", name: "Vision Model"))]",
        details: [
          "gh-1": detailJSON(
            location: "https://github.com/acme/vision-model-src/raw/main/model.pt")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "gh-1").first())
      #expect(try card.$repositoryResource.id == repoResource.requireID())
      #expect(card.$hubResource.id == nil)
    }
  }

  /// `download.pytorch.org` is one of the live catalog's actual hosts, and matches neither rule.
  /// `sourceURL` is still stored — that is the whole point of keeping it separate from the two
  /// foreign keys, since a bare null on those cannot distinguish this from Patra claiming
  /// nothing at all.
  @Test
  func `An unknown host stores sourceURL and resolves neither link`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "pt-1", name: "Detector"))]",
        details: [
          "pt-1": detailJSON(location: "https://download.pytorch.org/models/resnet.pth")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "pt-1").first())
      #expect(card.sourceURL == "https://download.pytorch.org/models/resnet.pth")
      #expect(card.$hubResource.id == nil)
      #expect(card.$repositoryResource.id == nil)
    }
  }

  /// The live catalog's one non-URL `location`: Patra answered with the literal six-character
  /// string `"test"`, quote marks included, on a real model card. `URLComponents` reports no
  /// host for it — the same as for any other scheme-less string — so this must store the raw
  /// value and resolve nothing, without the sweep throwing.
  @Test
  func `A malformed location is stored without resolving or throwing`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "malformed-1", name: "Odd Card"))]",
        details: [
          "malformed-1": #"{"ai_model":{"location":"\"test\""},"training_datasheet_uuid":null}"#
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "malformed-1").first())
      #expect(card.sourceURL == "\"test\"")
      #expect(card.$hubResource.id == nil)
      #expect(card.$repositoryResource.id == nil)
    }
  }

  /// Resolution depends on both sides existing, and re-runs every sweep to prove it: a card
  /// collected before its Hugging Face counterpart is registered resolves to nil on the first
  /// pass, and links itself on the next one once that counterpart shows up — with no new card or
  /// resource created in between.
  @Test
  func `Provenance resolves on a later sweep once its counterpart is registered`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "late-1", name: "Late Bloomer"))]",
        details: [
          "late-1": detailJSON(location: "https://huggingface.co/acme/late-bloomer")
        ])

      let job = SyncPatraCatalog()
      try await job.dequeue(queueContext(for: app), .init(id: try account.requireID()))

      let firstPass = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "late-1").first())
      #expect(firstPass.$hubResource.id == nil)

      let hfAccount = try await makeAccount(on: app.db, name: "acme", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "late-bloomer", type: .model)

      // Same stubbed client, same catalog — this is purely a second sweep finding a counterpart
      // that now exists, not a change in what Patra reports.
      try await job.dequeue(queueContext(for: app), .init(id: try account.requireID()))

      let secondPass = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "late-1").first())
      #expect(try secondPass.$hubResource.id == hubResource.requireID())
      // Still exactly one card — resolving the link is not a rediscovery.
      #expect(try await PatraCard.query(on: app.db).count() == 1)
    }
  }

  /// Resource names are stored lowercased (`Resource.Create.toModel()` calls `.lowercased()`),
  /// so a location whose owner/repo case differs from storage must still resolve.
  @Test
  func `Repository resolution matches case-insensitively against the lowercased stored name`()
    async throws
  {
    try await withInsightsApp { app in
      // Already-lowercase, standing in for what a real `Create` request would have written —
      // `makeAccount`/`makeResource` do not lowercase on a test's behalf.
      let ghAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let repoResource = try await makeResource(
        on: app.db, accountID: try ghAccount.requireID(), name: "camera_trap", type: .repository)

      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "case-1", name: "Camera Trap Detector"))]",
        details: [
          "case-1": detailJSON(location: "https://github.com/ICICLE-ai/Camera_Trap")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "case-1").first())
      #expect(try card.$repositoryResource.id == repoResource.requireID())
    }
  }

  /// `accounts` is unique on `(name, platform)`, not `name` alone — the checked-in dev seed
  /// genuinely reuses `icicle-ai` across five platforms — so matching an account by name without
  /// also constraining its platform lets a Hugging Face location resolve into a same-named
  /// resource under, say, the GitHub account instead. This is the real shape from the live seed:
  /// two `icicle-ai` accounts, one per platform, each owning a resource named `can-benchmark`.
  /// The location's own host has to decide which one the card links to.
  @Test
  func
    `Resolution picks the account on the location's own platform, not a same-named one elsewhere`()
    async throws
  {
    try await withInsightsApp { app in
      let ghAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let ghResource = try await makeResource(
        on: app.db, accountID: try ghAccount.requireID(), name: "can-benchmark",
        type: .repository)

      let hfAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .huggingface)
      let hfResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "can-benchmark", type: .dataset)

      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "collision-1", name: "CAN Benchmark"))]",
        details: [
          "collision-1": detailJSON(location: "https://huggingface.co/icicle-ai/can-benchmark")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "collision-1").first())
      #expect(try card.$hubResource.id == hfResource.requireID())
      #expect(card.$repositoryResource.id == nil)
      // The regression this guards against: matching by name alone would have linked the GitHub
      // resource instead, since it shares the name and would have been a candidate too.
      #expect(try card.$hubResource.id != ghResource.requireID())
    }
  }

  /// `Platform` has no `.gitlab` case, so a `gitlab.com` location — recognized as
  /// repository-shaped, the same as `github.com` — has no platform to filter an account against
  /// and must fail closed: `sourceURL` stored, both foreign keys nil. A same-named GitHub
  /// resource exists in this fixture specifically to prove an unfiltered match does not pick it
  /// up.
  @Test
  func `A gitlab_com location stores sourceURL and resolves nothing`() async throws {
    try await withInsightsApp { app in
      let ghAccount = try await makeAccount(on: app.db, name: "acme", platform: .github)
      _ = try await makeResource(
        on: app.db, accountID: try ghAccount.requireID(), name: "vision-model-src",
        type: .repository)

      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "gl-1", name: "Vision Model"))]",
        details: [
          "gl-1": detailJSON(location: "https://gitlab.com/acme/vision-model-src")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "gl-1").first())
      #expect(card.sourceURL == "https://gitlab.com/acme/vision-model-src")
      #expect(card.$hubResource.id == nil)
      #expect(card.$repositoryResource.id == nil)
    }
  }

  /// `training_datasheet_uuid` is captured free from the same detail response that carries
  /// `location` — Patra's own model-to-datasheet link, unrelated to cross-registry resolution.
  @Test
  func `training_datasheet_uuid is captured from the detail response`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      stubPatraCatalog(
        on: app,
        modelCards: "[\(modelCardJSON(uuid: "linked-1", name: "Linked Model"))]",
        details: [
          "linked-1": detailJSON(trainingDatasheetUUID: "sheet-uuid-123")
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let card = try #require(
        try await PatraCard.query(on: app.db).filter(\.$cardUUID == "linked-1").first())
      #expect(card.trainingDatasheetUUID == "sheet-uuid-123")
    }
  }

  /// A previous review flagged this exact case as untested: two cards under the same resource
  /// (two versions of `MegaDetector`, matching the live catalog's shape) both resolving to the
  /// same hub resource must produce one edge in `Resource.Public.links`, not two.
  /// `links(from:)`'s own dedup-by-id logic is exercised elsewhere against hand-built fixtures;
  /// this proves the sync job actually feeds it data that needs deduping.
  @Test
  func `Two cards of the same resource resolving to the same hub resource produce one link`()
    async throws
  {
    try await withInsightsApp { app in
      let hfAccount = try await makeAccount(on: app.db, name: "acme", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "mega-detector", type: .model)

      let account = try await makePatraAccount(on: app)
      let cards = [
        modelCardJSON(uuid: "mega-1", name: "MegaDetector", version: "v1"),
        modelCardJSON(uuid: "mega-2", name: "MegaDetector", version: "v2"),
      ].joined(separator: ",")
      let location = "https://huggingface.co/acme/mega-detector"
      stubPatraCatalog(
        on: app,
        modelCards: "[\(cards)]",
        details: [
          "mega-1": detailJSON(location: location),
          "mega-2": detailJSON(location: location),
        ])

      try await SyncPatraCatalog().dequeue(
        queueContext(for: app), .init(id: try account.requireID()))

      let resource = try #require(
        try await Resource.query(on: app.db)
          .filter(\.$type == .model)
          .filter(\.$name == "MegaDetector")
          .first())
      let resourceID = try resource.requireID()
      // Two cards, both resolved — the fixture actually exercises the dedup this test is about,
      // rather than only having one card to begin with.
      let hubResourceID = try hubResource.requireID()
      let resolvedCount = try await PatraCard.query(on: app.db)
        .filter(\.$resource.$id == resourceID)
        .filter(\.$hubResource.$id == hubResourceID)
        .count()
      #expect(resolvedCount == 2)

      // The same eager-load `ResourceController.show`/`index` use, so this proves what the API
      // actually returns rather than only what `PatraCard` rows say in isolation.
      let loaded = try #require(
        try await Resource.query(on: app.db)
          .filter(\.$id == resourceID)
          .with(\.$patraCards) { card in
            card.with(\.$hubResource) { $0.with(\.$account) }
            card.with(\.$repositoryResource) { $0.with(\.$account) }
          }
          .first())

      let links = try #require(loaded.toPublic().links)
      #expect(links.count == 1)
      #expect(links.first?.id == hubResourceID)
    }
  }

  // MARK: - SyncPatraDeployments

  /// A Patra model resource carrying one `PatraCard` per uuid given, matching what
  /// `SyncPatraCatalog` would have already registered — this job never discovers cards itself,
  /// only reads what `patra_cards` already says belongs to the resource.
  private func makePatraModel(
    on app: Application, cardUUIDs: [String], name: String = "MegaDetector"
  ) async throws -> Resource {
    let account = try await makePatraAccount(on: app)
    let resource = try await makeResource(
      on: app.db, accountID: try account.requireID(), name: name, type: .model)
    let resourceID = try resource.requireID()
    for uuid in cardUUIDs {
      try await PatraCard(resourceID: resourceID, cardUUID: uuid).create(on: app.db)
    }
    return resource
  }

  /// A JSON array of `count` deployment objects. Each element is an empty object —
  /// `PatraDeployment` is a deliberately empty `Content`, so only the array's length is ever
  /// exercised, matching what the job actually reads off it.
  private func deploymentsJSON(count: Int) -> String {
    "[" + Array(repeating: "{}", count: count).joined(separator: ",") + "]"
  }

  /// The headline case from the brief: `MegaDetector for Wildlife Detection`'s live shape,
  /// reduced to two cards. The resource-level reading is the sum across its cards, not either
  /// card's own count.
  @Test
  func `A resource with two cards records the sum of their deployments`() async throws {
    try await withInsightsApp { app in
      let resource = try await makePatraModel(on: app, cardUUIDs: ["card-a", "card-b"])
      let id = try resource.requireID()

      stubPagedAPI(on: app) { url in
        guard url.contains("skip=0") else { return nil }
        if url.contains("/modelcard/card-a/deployments") {
          return self.jsonResponse(.ok, self.deploymentsJSON(count: 38))
        }
        if url.contains("/modelcard/card-b/deployments") {
          return self.jsonResponse(.ok, self.deploymentsJSON(count: 14))
        }
        return nil
      }

      try await SyncPatraDeployments().dequeue(queueContext(for: app), .init(id: id))

      let result = try await readings(on: app.db, id)
      #expect(result[.deployments] == 52)

      let reloaded = try #require(try await Resource.find(id, on: app.db))
      #expect(reloaded.lastCollectedAt != nil)
    }
  }

  /// There is no datasheet deployments endpoint — Patra only runs models — so a `.dataset`
  /// resource has nothing to fetch. The sweep still counts as a successful collection: the
  /// question was asked and definitively answered as "not applicable", which is not the same as
  /// a failure and must not be retried as one.
  @Test
  func `A dataset resource records success with no deployments reading`() async throws {
    try await withInsightsApp { app in
      let account = try await makePatraAccount(on: app)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "Camera Trap Corpus",
        type: .dataset)
      let id = try resource.requireID()

      // No route answers anything: a job that reached the network here would fail loudly rather
      // than silently succeed, which is the point.
      let requests = stubPagedAPI(on: app) { _ in nil }

      try await SyncPatraDeployments().dequeue(queueContext(for: app), .init(id: id))

      #expect(try await Metric.query(on: app.db).filter(\.$resource.$id == id).count() == 0)
      #expect(requests.withLockedValue { $0 }.isEmpty)

      let reloaded = try #require(try await Resource.find(id, on: app.db))
      #expect(reloaded.lastCollectedAt != nil)
    }
  }

  /// Zero is a true observation, not an absence: the endpoint answered with an empty list, and
  /// that answer is what gets recorded — distinct from the dataset case above, where no request
  /// is made at all.
  @Test
  func `A model with zero deployments records a zero reading`() async throws {
    try await withInsightsApp { app in
      let resource = try await makePatraModel(on: app, cardUUIDs: ["card-zero"])
      let id = try resource.requireID()

      stubPagedAPI(on: app) { url in
        guard url.contains("/modelcard/card-zero/deployments"), url.contains("skip=0") else {
          return nil
        }
        return self.jsonResponse(.ok, "[]")
      }

      try await SyncPatraDeployments().dequeue(queueContext(for: app), .init(id: id))

      let metric = try #require(
        try await Metric.query(on: app.db)
          .filter(\.$resource.$id == id)
          .filter(\.$type == .deployments)
          .first())
      #expect(metric.reading == 0)
    }
  }

  /// `PatraAPI.page` asks for `limit=100`, so a single card's own deployments only ever page when
  /// they cross that boundary — 105 split into a 100-entry first page and a 5-entry second. Both
  /// must land in the sum, proving the job consumes everything `page` hands back rather than only
  /// the first response.
  @Test
  func `A card with more than 100 deployments is fully counted across pages`() async throws {
    try await withInsightsApp { app in
      let resource = try await makePatraModel(on: app, cardUUIDs: ["card-big"])
      let id = try resource.requireID()

      let requests = stubPagedAPI(on: app) { url in
        guard url.contains("/modelcard/card-big/deployments") else { return nil }
        if url.contains("skip=0") {
          return self.jsonResponse(.ok, self.deploymentsJSON(count: 100))
        }
        if url.contains("skip=100") {
          return self.jsonResponse(.ok, self.deploymentsJSON(count: 5))
        }
        return nil
      }

      try await SyncPatraDeployments().dequeue(queueContext(for: app), .init(id: id))

      let result = try await readings(on: app.db, id)
      #expect(result[.deployments] == 105)

      let paths = requests.withLockedValue { $0.map(\.url.string) }
        .filter { $0.contains("/modelcard/card-big/deployments") }
      #expect(paths.count == 2)
    }
  }

  @Test
  func `A sweep for a missing Patra resource is a no-op rather than a retried failure`()
    async throws
  {
    try await withInsightsApp { app in
      let requests = stubPagedAPI(on: app) { _ in nil }

      try await SyncPatraDeployments().dequeue(queueContext(for: app), .init(id: UUID()))

      #expect(requests.withLockedValue { $0 }.isEmpty)
    }
  }

  /// Both the non-200 failure path and the "fetch everything, then write" ordering in one test:
  /// `card-ok` would resolve cleanly on its own, `card-fail` 500s. If the job wrote as it went —
  /// the mistake Task 4's discovery job was sent back for making — this resource would end up
  /// with a metric summed from only one of its two cards. Instead nothing lands, and the
  /// schedule is not anchored on a sweep that never completed.
  @Test
  func `A failed deployments fetch writes no metric at all, even after another card succeeded`()
    async throws
  {
    try await withInsightsApp { app in
      let resource = try await makePatraModel(on: app, cardUUIDs: ["card-ok", "card-fail"])
      let id = try resource.requireID()

      stubPagedAPI(on: app) { url in
        if url.contains("/modelcard/card-ok/deployments"), url.contains("skip=0") {
          return self.jsonResponse(.ok, self.deploymentsJSON(count: 38))
        }
        if url.contains("/modelcard/card-fail/deployments") {
          return self.jsonResponse(.internalServerError, #"{"detail":"boom"}"#)
        }
        return nil
      }

      let error = await thrownJobError {
        try await SyncPatraDeployments().dequeue(queueContext(for: app), .init(id: id))
      }

      guard case .apiRequestFailed? = error else {
        Issue.record("expected apiRequestFailed, got \(String(describing: error?.description))")
        return
      }

      #expect(try await Metric.query(on: app.db).count() == 0)
      let reloaded = try #require(try await Resource.find(id, on: app.db))
      #expect(reloaded.lastCollectedAt == nil)
    }
  }
}
