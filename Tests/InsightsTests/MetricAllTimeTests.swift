import Fluent
import Foundation
import Testing

@testable import Insights

/// The double-counting these cover is the reason the watermark exists: GitHub hands back a
/// rolling 14-day window, so consecutive sweeps overlap and folding the whole window each time
/// re-adds every shared day.
@Suite("Metric all-time folding", .serialized)
struct MetricAllTimeTests {
  /// A completed day `offset` days before `now`'s UTC midnight. `offset: 0` is today, which is
  /// still accruing and must never be folded.
  private func day(_ offset: Int, count: Int, from now: Date) -> TrafficDay {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = utc.startOfDay(for: now)
    return TrafficDay(
      timestamp: midnight.addingTimeInterval(Double(offset) * 86_400),
      count: count,
      uniques: count,
    )
  }

  private func allTimeReading(on db: any Database, _ resourceID: Resource.IDValue) async throws
    -> Double?
  {
    try await Metric.query(on: db)
      .filter(\.$resource.$id == resourceID)
      .filter(\.$type == .clonesAllTime)
      .first()?
      .reading
  }

  @Test
  func `Re-folding the same window counts each day once`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()
      let now = Date()
      let days = [day(-3, count: 5, from: now), day(-2, count: 7, from: now)]

      try await Metric.foldDailyIntoAllTime(
        on: app.db, resourceID: id, type: .clones, days: days, now: now)
      #expect(try await allTimeReading(on: app.db, id) == 12)

      // The regression: a second sweep sees the same rolling window and must add nothing.
      try await Metric.foldDailyIntoAllTime(
        on: app.db, resourceID: id, type: .clones, days: days, now: now)
      #expect(try await allTimeReading(on: app.db, id) == 12)
    }
  }

  @Test
  func `Today is excluded while partial and counted once complete`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()
      let now = Date()
      let days = [day(-1, count: 10, from: now), day(0, count: 4, from: now)]

      // Today is still accruing: banking 4 now would record a partial figure and then skip
      // the rest of the day, because the watermark would have moved past it.
      try await Metric.foldDailyIntoAllTime(
        on: app.db, resourceID: id, type: .clones, days: days, now: now)
      #expect(try await allTimeReading(on: app.db, id) == 10)

      // A day later that same day is complete, and is picked up exactly once.
      try await Metric.foldDailyIntoAllTime(
        on: app.db,
        resourceID: id,
        type: .clones,
        days: days,
        now: now.addingTimeInterval(86_400),
      )
      #expect(try await allTimeReading(on: app.db, id) == 14)
    }
  }

  @Test
  func `A window reaching back past the watermark folds only its new tail`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()
      let now = Date()

      try await Metric.foldDailyIntoAllTime(
        on: app.db,
        resourceID: id,
        type: .clones,
        days: [day(-1, count: 10, from: now)],
        now: now,
      )
      #expect(try await allTimeReading(on: app.db, id) == 10)

      // A wider window covering days already counted. Every one of these predates the
      // watermark, so none may be added again.
      try await Metric.foldDailyIntoAllTime(
        on: app.db,
        resourceID: id,
        type: .clones,
        days: (2...5).map { day(-$0, count: 99, from: now) } + [day(-1, count: 10, from: now)],
        now: now,
      )
      #expect(try await allTimeReading(on: app.db, id) == 10)
    }
  }

  @Test
  func `No completed days leaves the total and watermark untouched`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()
      let now = Date()

      try await Metric.foldDailyIntoAllTime(
        on: app.db,
        resourceID: id,
        type: .clones,
        days: [day(0, count: 5, from: now)],
        now: now,
      )

      #expect(try await allTimeReading(on: app.db, id) == nil)
      let watermarks = try await MetricWatermark.query(on: app.db).count()
      #expect(watermarks == 0)
    }
  }

  /// Documents the loss rather than pretending it cannot happen: days that age out of the
  /// 14-day retention window before a sweep runs are gone, and the fold takes what is left
  /// without erroring. `Platform.maxCollectionIntervalDays` is what keeps this from arising.
  @Test
  func `A gap longer than retention folds only what is still in the window`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()
      let now = Date()

      try await Metric.foldDailyIntoAllTime(
        on: app.db,
        resourceID: id,
        type: .clones,
        days: [day(-1, count: 7, from: now)],
        now: now,
      )

      // Twenty days later GitHub still only offers the last 14; the six days in between are
      // unrecoverable.
      let later = now.addingTimeInterval(20 * 86_400)
      try await Metric.foldDailyIntoAllTime(
        on: app.db,
        resourceID: id,
        type: .clones,
        days: (1...14).map { day(-$0, count: 1, from: later) },
        now: later,
      )

      #expect(try await allTimeReading(on: app.db, id) == 21)
    }
  }

  @Test
  func `Gauges keep no all-time row`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()

      // Stars are reported in full every sweep, so the series is the record and there is
      // nothing to accumulate.
      try await Metric.addToAllTime(on: app.db, resourceID: id, type: .stars, reading: 42)

      let count = try await Metric.query(on: app.db)
        .filter(\.$resource.$id == id)
        .count()
      #expect(count == 0)
    }
  }

  /// The Hub reports its own lifetime figure, so re-running a sweep must not compound it the
  /// way accumulating the rolling 30-day `downloads` would.
  @Test
  func `Setting an all-time total replaces rather than accumulates`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()

      try await Metric.setAllTime(on: app.db, resourceID: id, type: .downloads, reading: 1000)
      try await Metric.setAllTime(on: app.db, resourceID: id, type: .downloads, reading: 1200)

      let totals = try await Metric.query(on: app.db)
        .filter(\.$resource.$id == id)
        .filter(\.$type == .downloadsAllTime)
        .all()

      #expect(totals.count == 1)
      #expect(totals.first?.reading == 1200)
    }
  }

  /// The exact case from the defect report: at the default cadence, two consecutive failures used
  /// to push the next successful collection to day 21, past GitHub's 14-day traffic window, and
  /// days 1-6 appeared in no response that was ever folded.
  @Test
  func `Two consecutive failures keep the gap inside the retention window`() async throws {
    try await withInsightsApp { app in
      _ = stubNotifier(on: app)
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let accountID = try account.requireID()
      _ = try await makeVault(on: app.db, accountID: accountID)
      let resource = try await makeResource(
        on: app.db, accountID: accountID, name: "insights", type: .repository,
        collectionIntervalDays: 7)

      // Day 0: a success, seven days ago.
      let daysAgo = { (d: Double) in Date().addingTimeInterval(-d * 86_400) }
      resource.lastCollectedAt = daysAgo(7)
      resource.scheduleNextCollection(from: daysAgo(7))
      try await resource.save(on: app.db)

      // Day 7 and again shortly after: two exhausted failures.
      for _ in 0..<2 {
        try await SyncGitHubRepoStats().error(
          queueContext(for: app),
          JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
          .init(id: try resource.requireID()),
        )
      }

      let settled = try #require(try await Resource.find(resource.id, on: app.db))
      let nextAttempt = try #require(settled.nextCollectionAt)
      let gapAtNextAttempt = nextAttempt.timeIntervalSince(daysAgo(7))

      // The whole point: the next attempt still lands inside the window, so a response then still
      // reaches back to day 0 and nothing has aged out. Before this it was day 21.
      #expect(gapAtNextAttempt < 14 * 86_400)
      #expect(settled.stallNotifiedAt == nil)
    }
  }
}
