import Fluent
import Vapor
import VaporToOpenAPI

import struct Foundation.Date
import struct Foundation.UUID

/// Read-only summaries of collected metrics, totalled in the database.
///
/// Replaces what the dashboard did in the browser: fetch raw readings one type at a time, each
/// capped at 1000 rows by `MetricController`, and add them up. That cap silently truncated
/// history, and stars reached it within months. These routes read every row in scope and return
/// one number per day, so the response size depends on the range, never on how much was collected.
///
/// All public, like every other read. Mounted under the `api` group, so they share its per-address
/// rate limit and its non-rejecting authenticators.
struct InsightsController: RouteCollection {
  /// Default span when `from` is omitted: a quarter, which is what the dashboard shows first.
  static let defaultSpanDays = 90

  /// Widest span accepted. Every day in range is a generated row per type or per resource, so
  /// the span bounds the query; two years covers any comparison the dashboard makes.
  static let maxSpanDays = 731

  /// Default and ceiling for `GET /insights/resources?limit=`.
  static let defaultPageSize = 50
  static let maxPageSize = 500

  /// Mounts the three summary routes under `/insights`.
  func boot(routes: any RoutesBuilder) throws {
    let insights = routes.grouped("insights")

    insights.get("summary", use: summary)
      .openAPI(
        tags: "Insights",
        summary: "Totals and daily series for every metric type in scope",
        query: .type(RangeQuery.self),
        response: .type(InsightsSummary.self),
      )
    insights.get("series", use: series)
      .openAPI(
        tags: "Insights",
        summary: "One metric type's history, by day or week, whole or by platform",
        query: .type(SeriesQuery.self),
        response: .type(InsightsSeries.self),
      )
    insights.get("resources", use: resources)
      .openAPI(
        tags: "Insights",
        summary: "Resources ranked by one metric, with their figures and a sparkline",
        query: .type(ResourcesQuery.self),
        response: .type(InsightsResourcePage.self),
      )
  }

  // MARK: - Query parameters

  /// The range and filters every insights route takes.
  struct RangeQuery: Content {
    /// First day, `YYYY-MM-DD`, UTC. Defaults to 90 days before `to`.
    var from: String?
    /// Last day, inclusive, `YYYY-MM-DD`, UTC. Defaults to today; a later day is read as today.
    var to: String?
    /// Only resources whose account is on this platform.
    var platform: Platform?
    /// Only this resource.
    var resourceID: UUID?

    enum CodingKeys: String, CodingKey {
      case from, to, platform, resourceID
    }
  }

  /// `RangeQuery` plus the series' own parameters.
  struct SeriesQuery: Content {
    var from: String?
    var to: String?
    var platform: Platform?
    var resourceID: UUID?
    /// The metric type to chart. Required.
    var type: MetricType?
    /// `day` (default) or `week`.
    var bucket: InsightBucket?
    /// `none` (default) or `platform`.
    var groupBy: InsightGrouping?

    enum CodingKeys: String, CodingKey {
      case from, to, platform, resourceID, type, bucket, groupBy
    }

    var range: RangeQuery {
      .init(from: from, to: to, platform: platform, resourceID: resourceID)
    }
  }

  /// `RangeQuery` plus sorting, paging, and a resource-kind filter.
  struct ResourcesQuery: Content {
    var from: String?
    var to: String?
    var platform: Platform?
    var resourceID: UUID?
    /// Metric type to rank by, on each resource's latest value. Defaults to `stars`.
    var sort: MetricType?
    /// `desc` (default) or `asc`. Resources without the metric sort last either way.
    var order: InsightOrder?
    /// 1–500, default 50.
    var limit: Int?
    /// Rows to skip, default 0.
    var offset: Int?
    /// Only resources of this kind.
    var kind: ResourceType?

    enum CodingKeys: String, CodingKey {
      case from, to, platform, resourceID, sort, order, limit, offset, kind
    }

    var range: RangeQuery {
      .init(from: from, to: to, platform: platform, resourceID: resourceID)
    }
  }

  // MARK: - Routes

  @Sendable
  /// One tile per metric type with any data in scope: current total, total at `from`, and the
  /// daily series between.
  func summary(req: Request) async throws -> InsightsSummary {
    let scope = try Self.scope(try req.query.decode(RangeQuery.self))
    let queries = try InsightsQueries(db: req.db, scope: scope)

    let current = Dictionary(
      try await queries.currentTotals().map { ($0.type, $0.v) }, uniquingKeysWith: { $1 })
    // `allCases` order, so tiles arrive in a stable order that does not depend on the data.
    let types = MetricType.allCases.filter { current[$0.rawValue] != nil }
    let series = Dictionary(
      grouping: try await queries.dailySeries(types: types, partition: .all), by: \.type)

    let tiles = types.map { type in
      let points = (series[type.rawValue] ?? []).map { InsightPoint(t: $0.t, v: $0.v) }
      return InsightTile(
        type: type,
        kind: type.insightKind,
        current: current[type.rawValue] ?? 0,
        atStart: Self.value(on: scope.fromDay, in: points),
        series: points,
      )
    }

    return InsightsSummary(
      generatedAt: Date(), from: scope.fromDay, to: scope.toDay, tiles: tiles)
  }

  @Sendable
  /// One metric type's carried-forward series, by day or by ISO week, whole or per platform.
  func series(req: Request) async throws -> InsightsSeries {
    let query = try req.query.decode(SeriesQuery.self)
    guard let type = query.type else {
      throw Abort(.badRequest, reason: "'type' is required, naming one metric type.")
    }
    let bucket = query.bucket ?? .day
    let grouping = query.groupBy ?? .none

    let scope = try Self.scope(query.range)
    let rows = try await InsightsQueries(db: req.db, scope: scope).dailySeries(
      types: [type],
      partition: grouping == .platform ? .platform : .all,
    )

    // Rows arrive ordered by group then day, so grouping preserves both orders.
    var keys: [String] = []
    var points: [String: [InsightPoint]] = [:]
    for row in rows {
      if points[row.grp] == nil { keys.append(row.grp) }
      points[row.grp, default: []].append(InsightPoint(t: row.t, v: row.v))
    }

    let groups = keys.map { key in
      let daily = points[key] ?? []
      return InsightSeriesGroup(
        key: key, points: bucket == .week ? Self.lastOfEachWeek(daily) : daily)
    }

    return InsightsSeries(type: type, bucket: bucket, groups: groups)
  }

  @Sendable
  /// A page of resources ranked by one metric's latest value, each with its latest and starting
  /// figures and that metric's daily sparkline.
  func resources(req: Request) async throws -> InsightsResourcePage {
    let query = try req.query.decode(ResourcesQuery.self)
    let sort = query.sort ?? .stars
    let order = query.order ?? .desc
    let limit = try requireInRange(
      query.limit ?? Self.defaultPageSize, 1...Self.maxPageSize, "limit")
    let offset = try requireNonNegative(query.offset ?? 0, "offset")

    let scope = try Self.scope(query.range, kind: query.kind)
    let queries = try InsightsQueries(db: req.db, scope: scope)

    let total = try await queries.resourceCount()
    let page = try await queries.resourcePage(
      sort: sort, order: order, limit: limit, offset: offset)
    let ids = page.map(\.id)
    guard !ids.isEmpty else { return InsightsResourcePage(total: total, rows: []) }

    let latest = Self.byResource(try await queries.latestValues(for: ids))
    let atStart = Self.byResource(try await queries.startValues(for: ids))
    let spark = Dictionary(
      grouping: try await queries.dailySeries(
        types: [sort], partition: .resource, restrictedTo: ids),
      by: \.grp)

    let rows = page.compactMap { row -> InsightResourceRow? in
      // Both columns come from enums, so a miss means the database holds a value this build does
      // not know: dropping the row beats failing the whole page over it.
      guard let kind = ResourceType(rawValue: row.kind),
        let platform = Platform(rawValue: row.platform)
      else { return nil }

      return InsightResourceRow(
        id: row.id,
        name: row.name,
        kind: kind,
        platform: platform,
        account: row.account,
        lastCollectedAt: row.lastCollectedAt,
        latest: latest[row.id] ?? [:],
        atStart: atStart[row.id] ?? [:],
        spark: (spark[row.id.uuidString.lowercased()] ?? []).map { InsightPoint(t: $0.t, v: $0.v) },
      )
    }

    return InsightsResourcePage(total: total, rows: rows)
  }

  // MARK: - Helpers

  /// Validates the shared parameters into a scope, applying the defaults.
  ///
  /// A `to` after today is read as today. Carrying the last value forward into days that have
  /// not happened would draw a flat line of invented points, and a client a timezone ahead of
  /// UTC can innocently ask for tomorrow; the response's `to` shows what was actually used.
  static func scope(_ query: RangeQuery, kind: ResourceType? = nil, now: Date = Date()) throws
    -> InsightsScope
  {
    let today = UTCDay.start(of: now)
    let requestedTo = try query.to.map { try requireDay($0, "to") } ?? today
    let to = min(requestedTo, today)
    let from =
      try query.from.map { try requireDay($0, "from") }
      ?? UTCDay.calendar.date(byAdding: .day, value: -defaultSpanDays, to: to) ?? to
    try requireDayRange(from: from, to: to, maxDays: maxSpanDays)

    return InsightsScope(
      from: from, to: to, platform: query.platform, resourceID: query.resourceID, kind: kind)
  }

  /// The value on `day`, when the series has a point there.
  ///
  /// A series starts on `from` exactly when something in scope had a value by then, because the
  /// query folds every earlier reading into a point on `from`. So a first point on any later day
  /// means there was nothing to report at the start, which is `null`, not zero.
  static func value(on day: String, in points: [InsightPoint]) -> Double? {
    guard let first = points.first, first.t == day else { return nil }
    return first.v
  }

  /// Reduces a daily series to the last point of each ISO week (Monday to Sunday, UTC).
  ///
  /// The last point *inside the range*: a week cut off by `to` reports its value on `to`, and a
  /// series starting midweek still gets that week's Sunday. Taking the week's end rather than an
  /// average is what the carried-forward values mean: each point is already a running level.
  static func lastOfEachWeek(_ points: [InsightPoint]) -> [InsightPoint] {
    var iso = Calendar(identifier: .iso8601)
    iso.timeZone = UTCDay.calendar.timeZone

    var weekly: [InsightPoint] = []
    var currentWeek: DateComponents?
    for point in points {
      guard let day = UTCDay.parse(point.t) else { continue }
      let week = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
      if week == currentWeek, !weekly.isEmpty {
        weekly[weekly.count - 1] = point
      } else {
        weekly.append(point)
        currentWeek = week
      }
    }
    return weekly
  }

  /// Folds per-resource, per-type rows into one `type → value` map per resource.
  private static func byResource(_ rows: [InsightsQueries.ResourceTypeValue])
    -> [UUID: [String: Double]]
  {
    var values: [UUID: [String: Double]] = [:]
    for row in rows {
      values[row.resourceID, default: [:]][row.type] = row.v
    }
    return values
  }
}
