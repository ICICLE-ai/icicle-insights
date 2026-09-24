import Fluent
import SQLKit
import Vapor

import struct Foundation.Date
import struct Foundation.UUID

/// The resources and days an insights request covers, already validated.
struct InsightsScope: Sendable {
  /// Midnight UTC of the first day.
  let from: Date
  /// Midnight UTC of the last day, inclusive.
  let to: Date
  let platform: Platform?
  let resourceID: UUID?
  /// Resource kind; only the resources endpoint takes it.
  let kind: ResourceType?

  var fromDay: String { UTCDay.string(from: from) }
  var toDay: String { UTCDay.string(from: to) }
}

/// What a series is partitioned by.
enum InsightsPartition {
  /// One group, keyed `all`.
  case all
  /// One group per account platform, keyed by its raw value.
  case platform
  /// One group per resource, keyed by its UUID. For the resources endpoint's sparklines.
  case resource
}

/// The SQL behind `InsightsController`, computed in the database rather than in Swift.
///
/// In SQL because the point of these endpoints is to stop shipping raw readings anywhere. The
/// dashboard used to download every reading, one request per type, capped at 1000 rows by
/// `MetricController`, and total them in the browser, which silently truncated history. These
/// queries read every row in scope with no cap and return one number per day.
///
/// Raw SQLKit rather than Fluent because the work is `DISTINCT ON`, window functions, and
/// `generate_series`, none of which FluentKit can express. Every value is bound; the only
/// interpolated SQL is a grouping expression or sort direction chosen from a closed Swift enum.
struct InsightsQueries {
  let sql: any SQLDatabase
  let scope: InsightsScope

  /// Wraps a Fluent database, which for PostgreSQL is also an `SQLDatabase`.
  init(db: any Database, scope: InsightsScope) throws {
    guard let sql = db as? any SQLDatabase else {
      throw Abort(.internalServerError, reason: "Insights need an SQL database.")
    }
    self.sql = sql
    self.scope = scope
  }

  // MARK: - Scope

  /// The `scope` CTE: in-scope resources, with what the resources endpoint shows about each.
  ///
  /// Excludes soft-deleted resources and resources of soft-deleted accounts. The second matters
  /// as much as the first: an orphaned resource's readings are still in `metrics`, and counting
  /// them would put a retired account back into every total.
  private func scopeCTE(restrictedTo ids: [UUID]? = nil) -> SQLQueryString {
    var cte: SQLQueryString = """
      scope AS (
        SELECT r.id, r.name, r.type::text AS kind, a.platform::text AS platform,
          a.name AS account, r.last_collected_at
        FROM resources r
        JOIN accounts a ON a.id = r.account_id
        WHERE r.deleted_at IS NULL AND a.deleted_at IS NULL
      """
    if let platform = scope.platform {
      cte += " AND a.platform = \(bind: platform.rawValue)::platform"
    }
    if let resourceID = scope.resourceID {
      cte += " AND r.id = \(bind: resourceID)"
    }
    if let kind = scope.kind {
      cte += " AND r.type = \(bind: kind.rawValue)::resource_type"
    }
    if let ids {
      cte += " AND r.id = ANY(\(bind: ids))"
    }
    cte += ")"
    return cte
  }

  /// End of the UTC day `day` (a `YYYY-MM-DD` bind), as a `timestamptz` expression.
  ///
  /// A bound on `recorded_at` itself rather than on its date, so the
  /// `(resource_id, type, recorded_at DESC)` index still serves the lookup.
  private func endOf(_ day: String) -> SQLQueryString {
    "((\(bind: day)::date + 1)::timestamp AT TIME ZONE 'UTC')"
  }

  // MARK: - Series

  /// One carried-forward value per type, group, and UTC day, as the database returns it.
  struct SeriesRow: Decodable {
    let type: String
    let grp: String
    let t: String
    let v: Double
  }

  /// Daily totals of `types` across the resources in scope, carried forward between readings.
  ///
  /// A resource's value on a day is its latest reading at or before that day's end; a group's is
  /// the sum over its resources; a day before a resource's first reading contributes nothing for
  /// it. Each group's series starts on the first day any of its resources has a value, and runs
  /// one point per day to `to`. Days before that are omitted rather than reported as zero, which
  /// would draw growth from nothing.
  ///
  /// Computed as a running sum of changes rather than by re-deriving every resource's latest
  /// reading on every day. Each resource contributes its value on its first day, then only the
  /// difference whenever it changes, so the query touches each reading once however long the
  /// range. Everything before `from` collapses into one point on `from`, which is also what
  /// makes the value on `from` equal the "as of `from`" figure.
  ///
  /// Collected types read `metrics`, keeping each resource's last reading of each UTC day.
  /// Lifetime types read `metric_daily_totals`, whose rows already are one per day, because the
  /// all-time row itself is updated in place and has no history.
  func dailySeries(
    types: [MetricType],
    partition: InsightsPartition,
    restrictedTo ids: [UUID]? = nil
  ) async throws -> [SeriesRow] {
    let collected = types.filter { $0.insightKind != .lifetime }.map(\.rawValue)
    let lifetime = types.filter { $0.insightKind == .lifetime }.map(\.rawValue)
    let group =
      switch partition {
      case .all: "'all'::text"
      case .platform: "s.platform"
      case .resource: "s.id::text"
      }

    let query: SQLQueryString =
      "WITH " + scopeCTE(restrictedTo: ids)
        + """
        ,
        source AS (
          (SELECT DISTINCT ON (m.resource_id, m.type, (m.recorded_at AT TIME ZONE 'UTC')::date)
              m.resource_id, m.type::text AS type,
              (m.recorded_at AT TIME ZONE 'UTC')::date AS day, m.reading
            FROM metrics m
            JOIN scope s ON s.id = m.resource_id
            WHERE m.type = ANY(\(bind: collected)::metric_type[])
              AND m.recorded_at < \(endOf(scope.toDay))
            ORDER BY m.resource_id, m.type, (m.recorded_at AT TIME ZONE 'UTC')::date,
              m.recorded_at DESC)
          UNION ALL
          SELECT d.resource_id, d.type::text, d.day, d.reading
            FROM metric_daily_totals d
            JOIN scope s ON s.id = d.resource_id
            WHERE d.type = ANY(\(bind: lifetime)::metric_type[])
              AND d.day <= \(bind: scope.toDay)::date
        ),
        points AS (
          (SELECT DISTINCT ON (src.resource_id, src.type)
              src.resource_id, src.type, \(bind: scope.fromDay)::date AS day, src.reading
            FROM source src
            WHERE src.day <= \(bind: scope.fromDay)::date
            ORDER BY src.resource_id, src.type, src.day DESC)
          UNION ALL
          SELECT src.resource_id, src.type, src.day, src.reading
            FROM source src
            WHERE src.day > \(bind: scope.fromDay)::date
        ),
        deltas AS (
          SELECT p.type, \(unsafeRaw: group) AS grp, p.day,
            p.reading - COALESCE(
              lag(p.reading) OVER (PARTITION BY p.resource_id, p.type ORDER BY p.day), 0
            ) AS delta
          FROM points p
          JOIN scope s ON s.id = p.resource_id
        ),
        changes AS (
          SELECT type, grp, day, sum(delta) AS delta
          FROM deltas
          GROUP BY type, grp, day
        ),
        grid AS (
          SELECT f.type, f.grp, g.day::date AS day
          FROM (SELECT type, grp, min(day) AS first_day FROM changes GROUP BY type, grp) f
          CROSS JOIN LATERAL generate_series(
            f.first_day::timestamp, \(bind: scope.toDay)::date::timestamp, interval '1 day'
          ) AS g(day)
        )
        SELECT g.type, g.grp, to_char(g.day, 'YYYY-MM-DD') AS t,
          (sum(COALESCE(c.delta, 0)) OVER (PARTITION BY g.type, g.grp ORDER BY g.day))::float8 AS v
        FROM grid g
        LEFT JOIN changes c ON c.type = g.type AND c.grp = g.grp AND c.day = g.day
        ORDER BY g.type, g.grp, g.day
        """

    return try await sql.raw(query).all(decoding: SeriesRow.self)
  }

  // MARK: - Current values

  /// A value per metric type, or per resource and type.
  struct TypeValue: Decodable {
    let type: String
    let v: Double
  }

  /// Per type, the sum over in-scope resources of each one's latest reading, regardless of range.
  ///
  /// Covers the lifetime types too: each resource has one all-time row, so its latest reading is
  /// its current total. A type appears here exactly when some in-scope resource has a reading of
  /// it, which is what decides the summary's tiles.
  func currentTotals() async throws -> [TypeValue] {
    let query: SQLQueryString =
      "WITH " + scopeCTE()
        + """
        ,
        latest AS (
          SELECT DISTINCT ON (m.resource_id, m.type) m.type, m.reading
          FROM metrics m
          JOIN scope s ON s.id = m.resource_id
          WHERE m.recorded_at IS NOT NULL
          ORDER BY m.resource_id, m.type, m.recorded_at DESC
        )
        SELECT type::text AS type, sum(reading)::float8 AS v
        FROM latest
        GROUP BY type
        """
    return try await sql.raw(query).all(decoding: TypeValue.self)
  }

  // MARK: - Resources

  /// One in-scope resource, as the resources endpoint lists it.
  struct ResourceRow: Decodable {
    let id: UUID
    let name: String
    let kind: String
    let platform: String
    let account: String
    let lastCollectedAt: Date?
  }

  /// How many resources are in scope, before paging.
  func resourceCount() async throws -> Int {
    let query: SQLQueryString = "WITH " + scopeCTE() + " SELECT count(*)::int AS total FROM scope"
    return try await sql.raw(query).first(decodingColumn: "total", as: Int.self) ?? 0
  }

  /// One page of in-scope resources, ordered by each one's latest `sort` reading.
  ///
  /// Nulls last in either direction, so a resource that has never reported the sort metric
  /// never outranks one that has. Name and then id break ties, which keeps paging stable: without
  /// a total order, equal values could swap between pages and a row appear twice or not at all.
  func resourcePage(sort: MetricType, order: InsightOrder, limit: Int, offset: Int)
    async throws -> [ResourceRow]
  {
    let direction =
      switch order {
      case .asc: "ASC"
      case .desc: "DESC"
      }
    let query: SQLQueryString =
      "WITH " + scopeCTE()
        + """
        ,
        sortval AS (
          SELECT DISTINCT ON (m.resource_id) m.resource_id, m.reading
          FROM metrics m
          JOIN scope s ON s.id = m.resource_id
          WHERE m.type = \(bind: sort.rawValue)::metric_type AND m.recorded_at IS NOT NULL
          ORDER BY m.resource_id, m.recorded_at DESC
        )
        SELECT s.id, s.name, s.kind, s.platform, s.account,
          s.last_collected_at AS "lastCollectedAt"
        FROM scope s
        LEFT JOIN sortval v ON v.resource_id = s.id
        ORDER BY v.reading \(unsafeRaw: direction) NULLS LAST, s.name ASC, s.id ASC
        LIMIT \(bind: limit) OFFSET \(bind: offset)
        """
    return try await sql.raw(query).all(decoding: ResourceRow.self)
  }

  /// A value for one resource and metric type.
  struct ResourceTypeValue: Decodable {
    let resourceID: UUID
    let type: String
    let v: Double
  }

  /// Each resource's latest reading of every type it has, regardless of range.
  func latestValues(for ids: [UUID]) async throws -> [ResourceTypeValue] {
    try await sql.raw(
      """
      SELECT DISTINCT ON (m.resource_id, m.type)
        m.resource_id AS "resourceID", m.type::text AS type, m.reading AS v
      FROM metrics m
      WHERE m.resource_id = ANY(\(bind: ids)) AND m.recorded_at IS NOT NULL
      ORDER BY m.resource_id, m.type, m.recorded_at DESC
      """
    ).all(decoding: ResourceTypeValue.self)
  }

  /// Each resource's value of every type as it stood at the end of `from`.
  ///
  /// Collected types from their latest reading by then. Lifetime types from the latest daily
  /// snapshot by then, not from the all-time row, whose value is today's and whose timestamp is
  /// only when it was first created.
  func startValues(for ids: [UUID]) async throws -> [ResourceTypeValue] {
    let lifetime = MetricType.allCases.filter { $0.insightKind == .lifetime }.map(\.rawValue)
    let query: SQLQueryString =
      """
      (SELECT DISTINCT ON (m.resource_id, m.type)
          m.resource_id AS "resourceID", m.type::text AS type, m.reading AS v
        FROM metrics m
        WHERE m.resource_id = ANY(\(bind: ids))
          AND NOT (m.type = ANY(\(bind: lifetime)::metric_type[]))
          AND m.recorded_at < \(endOf(scope.fromDay))
        ORDER BY m.resource_id, m.type, m.recorded_at DESC)
      UNION ALL
      (SELECT DISTINCT ON (d.resource_id, d.type)
          d.resource_id, d.type::text, d.reading
        FROM metric_daily_totals d
        WHERE d.resource_id = ANY(\(bind: ids)) AND d.day <= \(bind: scope.fromDay)::date
        ORDER BY d.resource_id, d.type, d.day DESC)
      """
    return try await sql.raw(query).all(decoding: ResourceTypeValue.self)
  }
}
