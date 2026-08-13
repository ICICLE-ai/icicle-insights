import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// How far a windowed metric has already been counted into its all-time total.
///
/// The traffic APIs return a rolling window, not a delta, so consecutive sweeps overlap.
/// Separate from `Resource.nextCollectionAt` — that says when to fetch next, this says what
/// has been counted — which is what lets a late sweep resume without loss or double-counting.
final class MetricWatermark: Model, @unchecked Sendable {
  static let schema = "metric_watermarks"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "resource_id")
  /// Resource whose rolling metric progress is tracked.
  var resource: Resource

  @Enum(key: "type")
  /// Rolling metric type tracked independently from other metrics.
  var type: MetricType

  /// Newest completed day already folded in. Days after it have not been counted.
  @Field(key: "counted_through")
  var countedThrough: Date

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  init() {}

  /// Creates the counted-through bookmark for one resource and rolling metric type.
  init(
    id: UUID? = nil,
    resourceID: Resource.IDValue,
    type: MetricType,
    countedThrough: Date,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
  ) {
    self.id = id
    $resource.id = resourceID
    self.type = type
    self.countedThrough = countedThrough
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
