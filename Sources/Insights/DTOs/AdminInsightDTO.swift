import Fluent
import Vapor

import struct Foundation.Date
import struct Foundation.UUID

struct WatermarkInsight: Content {
  var id: UUID?
  var resourceID: UUID
  var resourceName: String
  var type: MetricType
  var countedThrough: Date
  var updatedAt: Date?
}

struct QueueInsight: Content {
  var queue: String
  var pending: Int
  var processing: Int
  var schedulerLastSeenAt: Date?
  var schedulerState: String
}

struct JobFailureInsight: Content {
  var id: UUID?
  var resourceID: UUID?
  var accountID: UUID?
  var job: String
  var subject: String
  var identifier: String
  var details: String
  var severity: String
  var failedAt: Date
}

extension JobFailure {
  func toInsight() -> JobFailureInsight {
    .init(
      id: id,
      resourceID: $resource.id,
      accountID: $account.id,
      job: job,
      subject: subject,
      identifier: identifier,
      details: details,
      severity: severity,
      failedAt: failedAt,
    )
  }
}
