import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A hosting provider that owns accounts and determines resource collection routing.
enum Platform: String, Codable, CaseIterable {
  case github, ghcr, huggingface, npm, pypi

  /// Longest interval that still loses no days: GitHub's traffic endpoints retain 14, the Hub
  /// reports downloads over a trailing 30. Sweep slower and the gap days age out unrecoverably.
  var maxCollectionIntervalDays: Int {
    switch self {
    case .github: 14
    case .huggingface: 30
    case .ghcr, .npm, .pypi: 30
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
