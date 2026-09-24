import Vapor

import struct Foundation.Date
import struct Foundation.UUID

/// How a metric type's readings combine over time, which decides where its history comes from.
///
/// `CaseIterable` so the OpenAPI document lists the three values.
enum InsightKind: String, Codable, CaseIterable, Sendable {
  /// A running total kept by the server: the `*AllTime` types. One row, updated in place, so its
  /// history comes from `metric_daily_totals` and starts when that table was deployed.
  case lifetime
  /// A figure the platform reports over a trailing window, such as 14-day clones or 30-day
  /// downloads. Each reading stands alone; readings are never added together.
  case window
  /// A figure the platform reports in full each time, such as stars. The readings are the record.
  case gauge
}

extension MetricType {
  /// Which ``InsightKind`` this type is, and so how the insights endpoints chart it.
  ///
  /// Listed rather than derived from `allTime`: `deployments` has no all-time twin but is a gauge
  /// rather than a window, and only an explicit list says which of the two a new type is.
  var insightKind: InsightKind {
    switch self {
    case .authenticationsAllTime, .clonesAllTime, .downloadsAllTime, .pullsAllTime, .viewsAllTime:
      .lifetime
    case .authentications, .clones, .downloads, .pulls, .views:
      .window
    case .deployments, .forks, .likes, .stars, .subscribers:
      .gauge
    }
  }
}

/// One point of a daily or weekly series: a UTC day and the carried-forward value on it.
struct InsightPoint: Content, Equatable {
  /// `YYYY-MM-DD`, UTC.
  var t: String
  var v: Double
}

/// `GET /api/insights/summary`: one tile per metric type with data in scope.
struct InsightsSummary: Content {
  var generatedAt: Date
  /// `YYYY-MM-DD`, the first day of the range.
  var from: String
  /// `YYYY-MM-DD`, the last day of the range, inclusive.
  var to: String
  var tiles: [InsightTile]
}

/// One metric type, summed across every resource in scope.
struct InsightTile: Content {
  var type: MetricType
  var kind: InsightKind
  /// Sum of each resource's latest value, whatever the range. For a lifetime type, the sum of the
  /// all-time totals as they stand now.
  var current: Double
  /// The same sum as it stood at the end of `from`, or null when no resource in scope had a value
  /// by then. For a lifetime type that means no snapshot on or before `from`.
  var atStart: Double?
  /// One point per day from the first day any resource in scope had a value, through `to`.
  var series: [InsightPoint]

  enum CodingKeys: String, CodingKey {
    case type, kind, current, atStart, series
  }

  /// Written by hand so a missing `atStart` is an explicit `null`. Synthesised `Encodable` drops
  /// nil optionals, and a client should not have to tell "absent" from "no value" by a missing key.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(kind, forKey: .kind)
    try container.encode(current, forKey: .current)
    try container.encode(atStart, forKey: .atStart)
    try container.encode(series, forKey: .series)
  }
}

/// `GET /api/insights/series`: one metric type's history, whole or split by platform.
struct InsightsSeries: Content {
  var type: MetricType
  var bucket: InsightBucket
  var groups: [InsightSeriesGroup]
}

/// One line of a series: `all`, or one platform's raw value.
struct InsightSeriesGroup: Content {
  var key: String
  var points: [InsightPoint]
}

/// The spacing of a series' points.
enum InsightBucket: String, Codable, CaseIterable, Sendable {
  /// One point per UTC day.
  case day
  /// One point per ISO week: the value on that week's last day inside the range.
  case week
}

/// How a series is split into groups.
enum InsightGrouping: String, Codable, CaseIterable, Sendable {
  case none
  case platform
}

/// Sort direction for `GET /api/insights/resources`.
enum InsightOrder: String, Codable, CaseIterable, Sendable {
  case asc
  case desc
}

/// `GET /api/insights/resources`: one page of resources with their figures.
struct InsightsResourcePage: Content {
  /// Resources in scope, before paging.
  var total: Int
  var rows: [InsightResourceRow]
}

/// One resource and its figures.
struct InsightResourceRow: Content {
  var id: UUID
  var name: String
  var kind: ResourceType
  var platform: Platform
  /// The owning account's name.
  var account: String
  var lastCollectedAt: Date?
  /// Metric type raw value to its latest value, for every type the resource has.
  var latest: [String: Double]
  /// Metric type raw value to its value at the end of `from`, for every type that had one.
  var atStart: [String: Double]
  /// The sort metric's daily series in the range, from the resource's first value in it.
  var spark: [InsightPoint]

  enum CodingKeys: String, CodingKey {
    case id, name, kind, platform, account, lastCollectedAt, latest, atStart, spark
  }

  /// By hand so a resource never collected carries `"lastCollectedAt": null`, not a missing key.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(kind, forKey: .kind)
    try container.encode(platform, forKey: .platform)
    try container.encode(account, forKey: .account)
    try container.encode(lastCollectedAt, forKey: .lastCollectedAt)
    try container.encode(latest, forKey: .latest)
    try container.encode(atStart, forKey: .atStart)
    try container.encode(spark, forKey: .spark)
  }
}
