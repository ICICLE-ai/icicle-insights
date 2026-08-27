import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A collected measurement or its materialized all-time counterpart.
enum MetricType: String, Codable, CaseIterable {
  case authentications, clones, deployments, downloads, forks, likes, pulls, stars, subscribers,
    views

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
    // `deployments` joins this line for the same reason: Patra's count is read whole on every
    // sweep, so there is no rolling window, no watermark, and no all-time twin to fold into.
    case .deployments, .forks, .likes, .stars, .subscribers: nil
    }
  }

  /// Whether this type is a derived running total rather than a collected observation.
  ///
  /// Derived from `allTime` rather than listed separately: a case is its own all-time
  /// counterpart exactly when it *is* the counterpart, so a future pair added to that switch
  /// cannot forget to appear here. These are the types the API refuses to be handed directly —
  /// see `MetricController`, which folds accepted readings into them instead.
  var isAllTime: Bool { allTime == self }
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
