import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// One day's closing value of a resource's all-time total.
///
/// Written only by `Metric`'s all-time paths, as an upsert in the same transaction as the total
/// itself, so a day's row always holds the last total that day committed. It exists because the
/// total is one row updated in place: without these snapshots a lifetime metric has a present and
/// no past. Read by `InsightsController`, which carries each day forward to the next snapshot.
///
/// History begins when `MetricDailyTotals` was deployed; see that migration for why nothing
/// earlier is reconstructed.
final class MetricDailyTotal: Model, @unchecked Sendable {
  static let schema = "metric_daily_totals"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "resource_id")
  /// Resource whose total this snapshots.
  var resource: Resource

  @Enum(key: "type")
  /// The all-time type, such as `clonesAllTime`, never its rolling counterpart.
  var type: MetricType

  /// The UTC calendar day, stored as a PostgreSQL `date` and read back as that day's midnight UTC.
  @Field(key: "day")
  var day: Date

  @Field(key: "reading")
  /// The total as it stood after the day's last write.
  var reading: Double

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  init() {}

  /// Creates a snapshot row. Production code upserts through SQL instead; this is for fixtures.
  init(
    id: UUID? = nil,
    resourceID: Resource.IDValue,
    type: MetricType,
    day: Date,
    reading: Double,
  ) {
    self.id = id
    $resource.id = resourceID
    self.type = type
    self.day = day
    self.reading = reading
  }
}
