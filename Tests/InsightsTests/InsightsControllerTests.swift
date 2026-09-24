import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import Insights

/// The summary endpoints, driven over HTTP against readings seeded at chosen instants.
///
/// Readings are inserted with raw SQL because `Metric.recordedAt` is stamped on create, so a
/// Fluent insert cannot place one in the past. Every day is relative to today, since `to` may
/// not be later than today; a fixed calendar date would eventually fall out of the allowed span.
@Suite("Insights Controller", .serialized)
struct InsightsControllerTests {
  /// Midnight UTC `offset` days from a base 60 days ago, plus `hours`.
  private func day(_ offset: Int, hours: Double = 12) -> Date {
    UTCDay.start(of: Date()).addingTimeInterval(Double(offset - 60) * 86_400 + hours * 3600)
  }

  private func dayString(_ offset: Int) -> String {
    UTCDay.string(from: day(offset))
  }

  /// Inserts one reading at `date`.
  private func record(
    _ app: Application, _ resourceID: Resource.IDValue, _ type: MetricType, _ reading: Double,
    at date: Date
  ) async throws {
    let sql = try #require(app.db as? any SQLDatabase)
    try await sql.raw(
      """
      INSERT INTO metrics (id, resource_id, reading, type, recorded_at)
      VALUES (\(bind: UUID()), \(bind: resourceID), \(bind: reading),
        \(bind: type.rawValue)::metric_type, \(bind: date))
      """
    ).run()
  }

  /// Inserts one daily snapshot of an all-time total.
  private func snapshot(
    _ app: Application, _ resourceID: Resource.IDValue, _ type: MetricType, _ reading: Double,
    on offset: Int
  ) async throws {
    try await MetricDailyTotal(
      resourceID: resourceID, type: type, day: UTCDay.start(of: day(offset)), reading: reading
    ).create(on: app.db)
  }

  /// `GET` a path and decode the body, recording the status on failure.
  private func get<T: Decodable>(
    _ app: Application, _ path: String, as type: T.Type
  ) async throws -> T {
    var decoded: T?
    try await app.testing().test(
      .GET, path,
      afterResponse: { res async throws in
        #expect(res.status == .ok, "\(path): \(res.body.string)")
        decoded = try res.content.decode(T.self)
      })
    return try #require(decoded)
  }

  private func status(_ app: Application, _ path: String) async throws -> HTTPStatus {
    var status: HTTPStatus = .ok
    try await app.testing().test(
      .GET, path, afterResponse: { res async throws in status = res.status })
    return status
  }

  private func values(_ points: [InsightPoint]) -> [Double] { points.map(\.v) }

  // MARK: - Summary

  /// Carry-forward and summing across resources, with soft-deleted resources and resources of
  /// soft-deleted accounts left out entirely.
  @Test
  func `Summary sums each resource's latest reading, carried forward day by day`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai")
      let accountID = try account.requireID()
      let a = try await makeResource(on: app.db, accountID: accountID, name: "a")
      let b = try await makeResource(on: app.db, accountID: accountID, name: "b")
      let aID = try a.requireID()
      let bID = try b.requireID()

      try await record(app, aID, .stars, 10, at: day(-5))  // before the range
      try await record(app, aID, .stars, 12, at: day(2, hours: 1))
      try await record(app, aID, .stars, 13, at: day(2, hours: 20))  // the day's last wins
      try await record(app, aID, .stars, 20, at: day(6))
      try await record(app, bID, .stars, 5, at: day(4))
      try await record(app, bID, .stars, 7, at: day(8))
      try await record(app, aID, .clones, 40, at: day(3))

      // Neither of these may appear anywhere.
      let deleted = try await makeResource(on: app.db, accountID: accountID, name: "deleted")
      try await record(app, try deleted.requireID(), .stars, 1000, at: day(1))
      try await deleted.delete(on: app.db)
      let retired = try await makeAccount(on: app.db, name: "retired")
      let orphan = try await makeResource(
        on: app.db, accountID: try retired.requireID(), name: "orphan")
      try await record(app, try orphan.requireID(), .forks, 500, at: day(1))
      try await retired.delete(on: app.db)

      let summary = try await get(
        app, "api/insights/summary?from=\(dayString(0))&to=\(dayString(10))",
        as: InsightsSummary.self)

      #expect(summary.from == dayString(0))
      #expect(summary.to == dayString(10))
      #expect(summary.tiles.map(\.type) == [.clones, .stars])

      let stars = try #require(summary.tiles.first { $0.type == .stars })
      #expect(stars.kind == .gauge)
      #expect(stars.current == 27)
      #expect(stars.atStart == 10)
      #expect(stars.series.map(\.t) == (0...10).map(dayString))
      #expect(values(stars.series) == [10, 10, 13, 13, 18, 18, 25, 25, 27, 27, 27])

      // Nothing by `from`, so no starting value, and the series begins on the first reading.
      let clones = try #require(summary.tiles.first { $0.type == .clones })
      #expect(clones.kind == .window)
      #expect(clones.atStart == nil)
      #expect(clones.series.first?.t == dayString(3))
      #expect(clones.series.count == 8)
      #expect(values(clones.series).allSatisfy { $0 == 40 })
    }
  }

  /// The regression these endpoints exist for: the dashboard read at most 1000 raw rows per type.
  /// Here the earliest 200 readings are exactly the ones a 1000-newest cap would have dropped.
  @Test
  func `A series reads every reading, with no 1000-row cap`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let id = try resource.requireID()

      // 1200 hourly readings valued 1 through 1200, from midnight of day 0: 50 whole days.
      let sql = try #require(app.db as? any SQLDatabase)
      try await sql.raw(
        """
        INSERT INTO metrics (id, resource_id, reading, type, recorded_at)
        SELECT gen_random_uuid(), \(bind: id), g, 'stars'::metric_type,
          \(bind: day(0, hours: 0)) + (g - 1) * interval '1 hour'
        FROM generate_series(1, 1200) AS g
        """
      ).run()
      #expect(try await Metric.query(on: app.db).count() == 1200)

      let series = try await get(
        app, "api/insights/series?type=stars&from=\(dayString(0))&to=\(dayString(49))",
        as: InsightsSeries.self)

      let points = try #require(series.groups.first).points
      #expect(points.count == 50)
      // Each day closes on its 24th reading: 24, 48, ... 1200.
      #expect(values(points) == (1...50).map { Double($0 * 24) })
    }
  }

  /// Lifetime tiles take `current` from the all-time rows and their history from the daily
  /// snapshots. A total with no snapshots yet still counts now but has no history to draw.
  @Test
  func `Lifetime tiles read their history from daily snapshots`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      let a = try await makeResource(on: app.db, accountID: accountID, name: "a")
      let b = try await makeResource(on: app.db, accountID: accountID, name: "b")
      let aID = try a.requireID()

      try await makeMetric(on: app.db, resourceID: aID, reading: 100, type: .clonesAllTime)
      try await snapshot(app, aID, .clonesAllTime, 50, on: -2)
      try await snapshot(app, aID, .clonesAllTime, 80, on: 3)
      try await snapshot(app, aID, .clonesAllTime, 100, on: 7)
      try await makeMetric(
        on: app.db, resourceID: try b.requireID(), reading: 30, type: .viewsAllTime)

      let summary = try await get(
        app, "api/insights/summary?from=\(dayString(0))&to=\(dayString(10))",
        as: InsightsSummary.self)

      let clones = try #require(summary.tiles.first { $0.type == .clonesAllTime })
      #expect(clones.kind == .lifetime)
      #expect(clones.current == 100)
      #expect(clones.atStart == 50)
      #expect(values(clones.series) == [50, 50, 50, 80, 80, 80, 80, 100, 100, 100, 100])

      let views = try #require(summary.tiles.first { $0.type == .viewsAllTime })
      #expect(views.current == 30)
      #expect(views.atStart == nil)
      #expect(views.series.isEmpty)
    }
  }

  @Test
  func `Platform and resource filters narrow the scope`() async throws {
    try await withInsightsApp { app in
      let github = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let hub = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let repo = try await makeResource(on: app.db, accountID: try github.requireID(), name: "repo")
      let model = try await makeResource(on: app.db, accountID: try hub.requireID(), name: "model")
      try await record(app, try repo.requireID(), .stars, 3, at: day(1))
      try await record(app, try model.requireID(), .likes, 4, at: day(1))
      try await record(app, try model.requireID(), .stars, 9, at: day(1))

      let range = "from=\(dayString(0))&to=\(dayString(2))"
      let hubOnly = try await get(
        app, "api/insights/summary?\(range)&platform=huggingface", as: InsightsSummary.self)
      #expect(hubOnly.tiles.map(\.type) == [.likes, .stars])
      #expect(hubOnly.tiles.first { $0.type == .stars }?.current == 9)

      let repoOnly = try await get(
        app, "api/insights/summary?\(range)&resourceID=\(try repo.requireID())",
        as: InsightsSummary.self)
      #expect(repoOnly.tiles.map(\.type) == [.stars])
      #expect(repoOnly.tiles.first?.current == 3)
    }
  }

  // MARK: - Series

  @Test
  func `A series splits by platform`() async throws {
    try await withInsightsApp { app in
      let github = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let hub = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
      let repo = try await makeResource(on: app.db, accountID: try github.requireID(), name: "repo")
      let model = try await makeResource(on: app.db, accountID: try hub.requireID(), name: "model")
      try await record(app, try repo.requireID(), .stars, 3, at: day(0))
      try await record(app, try repo.requireID(), .stars, 5, at: day(2))
      try await record(app, try model.requireID(), .stars, 9, at: day(1))

      let range = "from=\(dayString(0))&to=\(dayString(3))"
      let split = try await get(
        app, "api/insights/series?type=stars&groupBy=platform&\(range)", as: InsightsSeries.self)
      #expect(split.groups.map(\.key) == ["github", "huggingface"])
      #expect(values(split.groups[0].points) == [3, 3, 5, 5])
      #expect(values(split.groups[1].points) == [9, 9, 9])
      #expect(split.groups[1].points.first?.t == dayString(1))

      let whole = try await get(
        app, "api/insights/series?type=stars&\(range)", as: InsightsSeries.self)
      #expect(whole.groups.map(\.key) == ["all"])
      #expect(values(whole.groups[0].points) == [3, 12, 14, 14])
    }
  }

  /// A week's point is its value on the last day of that ISO week inside the range: Sunday, or
  /// `to` for a week the range cuts off.
  @Test
  func `Week buckets take each ISO week's last day in range`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      for offset in 0...20 {
        try await record(app, try resource.requireID(), .stars, Double(offset), at: day(offset))
      }

      let range = "from=\(dayString(0))&to=\(dayString(20))"
      let daily = try await get(
        app, "api/insights/series?type=stars&\(range)", as: InsightsSeries.self)
      let weekly = try await get(
        app, "api/insights/series?type=stars&bucket=week&\(range)", as: InsightsSeries.self)
      #expect(weekly.bucket == .week)

      var iso = Calendar(identifier: .iso8601)
      iso.timeZone = TimeZone(secondsFromGMT: 0)!
      let expected = try #require(daily.groups.first).points.filter { point in
        let date = UTCDay.parse(point.t)!
        return iso.component(.weekday, from: date) == 1 || point.t == dayString(20)
      }
      #expect(weekly.groups.first?.points == expected)
      #expect((3...4).contains(expected.count))
    }
  }

  // MARK: - Resources

  @Test
  func `Resources rank by the sort metric's latest value, nulls last, and page`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai")
      let accountID = try account.requireID()
      let low = try await makeResource(on: app.db, accountID: accountID, name: "low")
      let high = try await makeResource(on: app.db, accountID: accountID, name: "high")
      let none = try await makeResource(on: app.db, accountID: accountID, name: "none")
      let lowID = try low.requireID()
      try await record(app, lowID, .stars, 2, at: day(-3))
      try await record(app, lowID, .stars, 5, at: day(2))
      try await record(app, lowID, .forks, 1, at: day(1))
      try await record(app, try high.requireID(), .stars, 50, at: day(1))
      try await record(app, try none.requireID(), .forks, 8, at: day(1))

      let range = "from=\(dayString(0))&to=\(dayString(3))"
      let desc = try await get(
        app, "api/insights/resources?\(range)", as: InsightsResourcePage.self)
      #expect(desc.total == 3)
      #expect(desc.rows.map(\.name) == ["high", "low", "none"])

      let asc = try await get(
        app, "api/insights/resources?sort=stars&order=asc&\(range)", as: InsightsResourcePage.self)
      #expect(asc.rows.map(\.name) == ["low", "high", "none"])

      let page = try await get(
        app, "api/insights/resources?limit=1&offset=1&\(range)", as: InsightsResourcePage.self)
      #expect(page.total == 3)
      let row = try #require(page.rows.first)
      #expect(row.name == "low")
      #expect(row.kind == .model)
      #expect(row.platform == .github)
      #expect(row.account == "icicle-ai")
      #expect(row.latest == ["stars": 5, "forks": 1])
      #expect(row.atStart == ["stars": 2])
      #expect(values(row.spark) == [2, 2, 5, 5])
      #expect(row.spark.first?.t == dayString(0))
    }
  }

  @Test
  func `Resources filter by kind, and say explicitly when never collected`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      _ = try await makeResource(on: app.db, accountID: accountID, name: "repo", type: .repository)
      _ = try await makeResource(on: app.db, accountID: accountID, name: "set", type: .dataset)

      try await app.testing().test(
        .GET, "api/insights/resources?kind=dataset",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let page = try res.content.decode(InsightsResourcePage.self)
          #expect(page.total == 1)
          #expect(page.rows.map(\.name) == ["set"])
          // Present and null, not missing: a client should not have to tell the two apart.
          #expect(res.body.string.contains(#""lastCollectedAt":null"#))
          #expect(res.body.string.contains(#""spark":[]"#))
        })
    }
  }

  // MARK: - Parameters

  @Test
  func `The range defaults to the 90 days up to today`() async throws {
    try await withInsightsApp { app in
      let summary = try await get(app, "api/insights/summary", as: InsightsSummary.self)
      let today = UTCDay.start(of: Date())
      #expect(summary.to == UTCDay.string(from: today))
      #expect(summary.from == UTCDay.string(from: today.addingTimeInterval(-90 * 86_400)))
      #expect(summary.tiles.isEmpty)
    }
  }

  /// Carrying values into days that have not happened would invent points.
  @Test
  func `A future end date is read as today`() async throws {
    try await withInsightsApp { app in
      let tomorrow = UTCDay.string(from: Date().addingTimeInterval(86_400))
      let summary = try await get(
        app, "api/insights/summary?to=\(tomorrow)", as: InsightsSummary.self)
      #expect(summary.to == UTCDay.string(from: Date()))
    }
  }

  @Test(arguments: [
    "api/insights/summary?from=2026-09-10&to=2026-09-01",  // reversed
    "api/insights/summary?from=2020-01-01&to=2026-01-01",  // over two years
    "api/insights/summary?from=2026-9-1",  // not zero-padded
    "api/insights/summary?to=2026-02-30",  // not a date
    "api/insights/summary?platform=myspace",
    "api/insights/summary?resourceID=not-a-uuid",
    "api/insights/series",  // type is required
    "api/insights/series?type=stars&bucket=month",
    "api/insights/series?type=stars&groupBy=account",
    "api/insights/resources?limit=0",
    "api/insights/resources?limit=501",
    "api/insights/resources?offset=-1",
    "api/insights/resources?sort=popularity",
    "api/insights/resources?order=sideways",
    "api/insights/resources?kind=spaceship",
  ])
  func `Invalid parameters are a bad request`(path: String) async throws {
    try await withInsightsApp { app in
      let answered = try await status(app, path)
      #expect(answered == .badRequest, "\(path)")
    }
  }

  /// Reads are public, like every other read: no credential, still answered.
  @Test
  func `The routes are public and documented`() async throws {
    try await withInsightsApp { app in
      for path in ["summary", "series?type=stars", "resources"] {
        #expect(try await status(app, "api/insights/\(path)") == .ok)
      }

      try await app.testing().test(
        .GET, "openapi.json",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          // Decoded rather than searched: the encoder escapes every `/` in the document.
          let document = try JSONSerialization.jsonObject(with: Data(res.body.string.utf8))
          let paths = try #require((document as? [String: Any])?["paths"] as? [String: Any])
          for route in ["/api/insights/summary", "/api/insights/series", "/api/insights/resources"]
          {
            #expect(paths[route] != nil, "\(route) missing from the OpenAPI document")
          }
        })
    }
  }
}
