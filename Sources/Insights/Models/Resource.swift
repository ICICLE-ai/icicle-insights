import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A catalog classification for an account-owned artifact or service.
///
/// `CaseIterable` makes SwiftOpenAPI emit the allowed values instead of a bare string.
enum ResourceType: String, Codable, CaseIterable {
  case agent, container, dataset, model, package, repository, service
}

/// A collectable artifact owned by a platform account.
final class Resource: Model, @unchecked Sendable {
  static let schema = "resources"

  /// Under every platform's retention window with margin, so a missed sweep loses nothing.
  static let defaultCollectionIntervalDays = 7

  @ID(key: .id)
  var id: UUID?

  @Field(key: "name")
  /// Normalized provider-specific resource name or path.
  var name: String

  @Enum(key: "type")
  /// Catalog classification independent from the hosting platform.
  var type: ResourceType

  @Parent(key: "account_id")
  /// Platform account that owns the resource.
  var account: Account

  /// When the next sweep should collect this. Nil is skipped by the sweep's `<= now` filter.
  @OptionalField(key: "next_collection_at")
  var nextCollectionAt: Date?

  /// Days between sweeps, capped by `Platform.maxCollectionIntervalDays`.
  @Field(key: "collection_interval_days")
  var collectionIntervalDays: Int

  /// When a collection last *succeeded*. The gap between successes is what the provider's
  /// retention window governs, so this — not `nextCollectionAt` — is what the backoff and the
  /// data-loss guard measure from. Nil until the first success; callers fall back to `createdAt`.
  @OptionalField(key: "last_collected_at")
  var lastCollectedAt: Date?

  /// When this resource's retention-window alert last fired, cleared on the next success.
  /// Without it the alert would repeat on every failure for the rest of the outage, which is
  /// exactly the noise the capped backoff exists to avoid.
  @OptionalField(key: "stall_notified_at")
  var stallNotifiedAt: Date?

  @Children(for: \.$resource)
  /// Time-series and materialized total readings for this resource.
  var metrics: [Metric]

  @Children(for: \.$resource)
  /// Published versions associated with this resource.
  var releases: [Release]

  @Children(for: \.$resource)
  /// Patra cards that name this resource.
  ///
  /// Exists for provenance projection: `toPublic()` reads each card's `hubResource` and
  /// `repositoryResource` to build `Public.links` — the other registries this same artifact is
  /// also known under, per whatever Patra recorded on this resource's own cards.
  var patraCards: [PatraCard]

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  @Timestamp(key: "deleted_at", on: .delete)
  var deletedAt: Date?

  init() {}

  /// Creates a resource with an optional due date and configurable collection cadence.
  init(
    id: UUID? = nil,
    name: String,
    type: ResourceType,
    accountID: Account.IDValue,
    nextCollectionAt: Date? = nil,
    collectionIntervalDays: Int = Resource.defaultCollectionIntervalDays,
    lastCollectedAt: Date? = nil,
    stallNotifiedAt: Date? = nil,
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
    self.lastCollectedAt = lastCollectedAt
    self.stallNotifiedAt = stallNotifiedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  /// From `now`, not the previous due date: after downtime a stale date would leave the
  /// resource due again immediately, dispatching once per missed interval.
  /// - Parameter now: The successful dispatch time from which the next interval begins.
  func scheduleNextCollection(from now: Date = Date()) {
    nextCollectionAt = now.addingTimeInterval(Double(collectionIntervalDays) * 86_400)
  }

  /// Records a completed collection and books the next one from it.
  ///
  /// The sweep advances `nextCollectionAt` when it dispatches, which is a lease rather than a
  /// schedule: it keeps the resource out of the next sweep while an outcome is outstanding. This
  /// is what settles it once the outcome is known, so the cadence anchors on the last success.
  ///
  /// Clearing `stallNotifiedAt` is what re-arms the retention-window alert. A resource that
  /// recovered and later stalls again is a new outage and deserves to be told about again.
  /// - Parameters:
  ///   - db: Database to save through.
  ///   - now: The instant the collection completed.
  func recordSuccessfulCollection(on db: any Database, now: Date = Date()) async throws {
    lastCollectedAt = now
    stallNotifiedAt = nil
    scheduleNextCollection(from: now)
    try await save(on: db)
  }
}
