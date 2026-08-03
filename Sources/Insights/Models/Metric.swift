import Fluent

import struct Foundation.Date
import struct Foundation.UUID

enum MetricType: String, Codable, CaseIterable {
  case authentications, clones, downloads, forks, likes, pulls, stars, subscribers, views

  // All Time / Totals
  case authenticationsAllTime, clonesAllTime, downloadsAllTime, forksAllTime, likesAllTime,
    pullsAllTime, starsAllTime, subscribersAllTime, viewsAllTime
}

final class Metric: Model, @unchecked Sendable {
  static let schema = "metrics"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "resource_id")
  var resource: Resource

  @Field(key: "reading")
  var reading: Double

  @Enum(key: "type")
  var type: MetricType

  @Timestamp(key: "recorded_at", on: .create)
  var recordedAt: Date?

  init() {}

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
