import Fluent

import struct Foundation.Date
import struct Foundation.UUID

// CaseIterable is what makes SwiftOpenAPI emit the allowed values as an enum in the
// generated schema rather than a bare string.
enum ResourceType: String, Codable, CaseIterable {
  case container, dataset, model, package, repository, service
}

final class Resource: Model, @unchecked Sendable {
  static let schema = "resources"

  /// Under every platform's retention window with margin, so a missed sweep loses nothing.
  static let defaultCollectionIntervalDays = 7

  @ID(key: .id)
  var id: UUID?

  @Field(key: "name")
  var name: String

  @Enum(key: "type")
  var type: ResourceType

  @Parent(key: "account_id")
  var account: Account

  /// When the next sweep should collect this. Nil is skipped by the sweep's `<= now` filter.
  @OptionalField(key: "next_collection_at")
  var nextCollectionAt: Date?

  /// Days between sweeps, capped by `Platform.maxCollectionIntervalDays`.
  @Field(key: "collection_interval_days")
  var collectionIntervalDays: Int

  @Children(for: \.$resource)
  var metrics: [Metric]

  @Children(for: \.$resource)
  var releases: [Release]

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  @Timestamp(key: "deleted_at", on: .delete)
  var deletedAt: Date?

  init() {}

  init(
    id: UUID? = nil,
    name: String,
    type: ResourceType,
    accountID: Account.IDValue,
    nextCollectionAt: Date? = nil,
    collectionIntervalDays: Int = Resource.defaultCollectionIntervalDays,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    deletedAt: Date? = nil,
  ) {
    self.id = id
    self.name = name
    self.type = type
    $account.id = accountID
    self.nextCollectionAt = nextCollectionAt
    self.collectionIntervalDays = collectionIntervalDays
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  /// From `now`, not the previous due date: after downtime a stale date would leave the
  /// resource due again immediately, dispatching once per missed interval.
  func scheduleNextCollection(from now: Date = Date()) {
    nextCollectionAt = now.addingTimeInterval(Double(collectionIntervalDays) * 86_400)
  }
}
