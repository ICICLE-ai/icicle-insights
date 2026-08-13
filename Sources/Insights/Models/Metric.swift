import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A collected measurement or its materialized all-time counterpart.
enum MetricType: String, Codable, CaseIterable {
  case authentications, clones, downloads, forks, likes, pulls, stars, subscribers, views

  // All Time / Totals
  case authenticationsAllTime, clonesAllTime, downloadsAllTime, pullsAllTime, viewsAllTime

  /// All-time counterpart, for metrics the API reports as a rolling window. Nil when a
  /// reading is already a lifetime total, since the series itself is the total and keeping
  /// it lets the figure fall as well as rise.
  var allTime: MetricType? {
    switch self {
    case .authentications, .authenticationsAllTime: .authenticationsAllTime
    case .clones, .clonesAllTime: .clonesAllTime
    case .downloads, .downloadsAllTime: .downloadsAllTime
    case .pulls, .pullsAllTime: .pullsAllTime
    case .views, .viewsAllTime: .viewsAllTime
    case .forks, .likes, .stars, .subscribers: nil
    }
  }
}

/// A timestamped numeric reading associated with one resource.
final class Metric: Model, @unchecked Sendable {
  static let schema = "metrics"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "resource_id")
  /// Resource measured by this reading.
  var resource: Resource

  @Field(key: "reading")
  /// Numeric observation recorded by the platform sync.
  var reading: Double

  @Enum(key: "type")
  /// Semantic kind of the observation.
  var type: MetricType

  @Timestamp(key: "recorded_at", on: .create)
  /// Server-assigned timestamp for this observation.
  var recordedAt: Date?

  init() {}

  /// Creates a metric reading for a resource.
  init(
    id: UUID? = nil,
    resourceID: Resource.IDValue,
    reading: Double,
    type: MetricType,
    recordedAt: Date? = nil,
  ) {
    self.id = id
    $resource.id = resourceID
    self.reading = reading
    self.type = type
    self.recordedAt = recordedAt
  }
}
