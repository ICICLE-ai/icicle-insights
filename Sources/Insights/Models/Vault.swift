import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// Metadata linking an account to a secret stored externally in Tapis Vault.
///
/// The token value is never persisted in this model; `name` is the Tapis secret key.
final class Vault: Model, @unchecked Sendable {
  static let schema = "vaults"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "account_id")
  /// Account that consumes the referenced platform token.
  var account: Account

  @Field(key: "name")
  /// Name of the secret stored in Tapis Vault.
  var name: String

  @Timestamp(key: "expires_at", on: .none)
  /// Expected expiration date used for credential rotation.
  var expiresAt: Date?

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  init() {}

  /// Creates local metadata for an externally managed Tapis Vault secret.
  init(
    id: UUID? = nil,
    accountID: Account.IDValue,
    name: String,
    expiresAt: Date? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
  ) {
    self.id = id
    $account.id = accountID
    self.name = name
    self.expiresAt = expiresAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// Canonical Tapis Vault secret name: `insights-<platform>-<account>`.
  ///
  /// The platform prefix is what disambiguates accounts that share a name across registries —
  /// an "icicle-ai" org can exist on GitHub, npm, and PyPI at once, and a bare account name
  /// gave an admin no way to tell which vault they were about to create. Deriving the name here
  /// instead of accepting it from the client also makes the convention impossible to violate.
  static func credentialName(platform: Platform, accountName: String) -> String {
    var sanitized = ""
    for character in accountName.lowercased() {
      if character.isLetter || character.isNumber {
        sanitized.append(character)
      } else if sanitized.last != "-" {
        sanitized.append("-")
      }
    }
    while sanitized.hasPrefix("-") {
      sanitized.removeFirst()
    }
    while sanitized.hasSuffix("-") {
      sanitized.removeLast()
    }
    return "insights-\(platform.rawValue)-\(sanitized)"
  }
}
