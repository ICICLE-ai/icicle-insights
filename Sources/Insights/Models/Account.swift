import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A hosting provider that owns accounts and determines resource collection routing.
enum Platform: String, Codable, CaseIterable {
  // Append order, not alphabetical: `composition-chart.ts:125` colours by
  // `PLATFORM_ORDER.indexOf`, so inserting a new case mid-array recolours every platform after
  // it. A new platform always goes last.
  case github, ghcr, huggingface, npm, pypi, patra

  /// Longest cadence the API accepts for this platform.
  ///
  /// Not the same as the retention window, and deliberately shorter than it where one exists: a
  /// cadence equal to the window leaves no headroom, so a single delayed sweep loses days. GitHub
  /// is capped at half its 14-day window. That margin is not "one missed collection" — a
  /// genuinely missed cadence still reaches the full window with nothing left. What actually
  /// protects it is that a failed collection re-books on a capped backoff instead of costing a
  /// whole interval, so under this policy a miss costs at most twelve hours, never a full
  /// cadence. The Hub has no window to lose against, so its limit is about series density rather
  /// than correctness.
  var maxCollectionIntervalDays: Int {
    switch self {
    case .github: 7
    case .huggingface: 30
    case .ghcr, .npm, .pypi: 30
    case .patra: 30
    }
  }

  /// How far back the provider still returns daily values, when its metrics are rolling windows
  /// folded through a watermark.
  ///
  /// Nil means this platform cannot lose data to a window at all. The Hub reports
  /// `downloadsAllTime` itself and `Metric.setAllTime` assigns it, so a late sweep costs nothing
  /// permanently; only GitHub's `clones` and `views` are accumulated day by day and age out.
  var retentionWindowDays: Int? {
    switch self {
    case .github: 14
    case .ghcr, .huggingface, .npm, .pypi: nil
    case .patra: nil
    }
  }

  /// Whether a sync job exists to collect this platform at all.
  ///
  /// Mirrors the routing in `Queue.dispatchSync`, and both switches are exhaustive on purpose: a
  /// new platform fails to compile in both places rather than silently becoming uncollectable in
  /// one of them.
  ///
  /// The sweep does not need this — skipping a catalogued-but-uncollectable resource is the right
  /// behaviour there. An operator-triggered collection does: dispatching nothing and returning
  /// success leaves the caller waiting on a verdict that can never arrive.
  var isCollectable: Bool {
    switch self {
    case .github, .huggingface, .patra: true
    case .ghcr, .npm, .pypi: false
    }
  }
}

/// A platform identity that owns resources and optionally references a Tapis Vault secret.
final class Account: Model, @unchecked Sendable {
  static let schema = "accounts"

  @ID(key: .id)
  var id: UUID?

  @Field(key: "name")
  /// Normalized provider account or organization name.
  var name: String

  @Enum(key: "platform")
  /// Provider used to route this account's resources to sync jobs.
  var platform: Platform

  @Field(key: "followers")
  /// Latest collected account follower snapshot.
  var followers: Int

  @Children(for: \.$account)
  /// Resources published by this account.
  var resources: [Resource]

  @OptionalChild(for: \.$account)
  /// Metadata referencing the account's platform token in Tapis Vault.
  var vault: Vault?

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  @Timestamp(key: "deleted_at", on: .delete)
  var deletedAt: Date?

  init() {}

  /// Creates an account model with its current follower snapshot.
  init(
    id: UUID? = nil,
    name: String,
    platform: Platform,
    followers: Int,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    deletedAt: Date? = nil,
  ) {
    self.id = id
    self.name = name
    self.platform = platform
    self.followers = followers
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}
