import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// The revocable half of a webhook credential.
///
/// The credential itself is a signed JWT held by the deployed service; it carries the resource
/// binding and the expiry, both tamper-proof. This row exists for the one thing a signature
/// cannot express: a token already handed out has no way to learn it was cancelled. Matching
/// `jti` against a live row on every request is what makes revocation immediate.
///
/// Deliberately holds no credential — only a random identifier and metadata — so nothing secret
/// enters the database this API already serves.
final class ServiceToken: Model, @unchecked Sendable {
  static let schema = "service_tokens"

  @ID(key: .id)
  var id: UUID?

  @Field(key: "jti")
  /// Matches the `jti` claim of the issued JWT. Unique, and the lookup key on every request.
  var jti: UUID

  @Parent(key: "resource_id")
  /// The only resource this token may post metrics for.
  var resource: Resource

  @Field(key: "label")
  /// Operator-chosen name identifying the deployment, e.g. `prod-inference`.
  var label: String

  @Field(key: "expires_at")
  /// Mirrors the token's `exp` claim. The claim is what verification enforces; this copy exists
  /// so an operator can see what is about to lapse without decoding anything.
  var expiresAt: Date

  @OptionalField(key: "revoked_at")
  /// Set to withdraw the token. Non-nil means the next request carrying it is refused.
  var revokedAt: Date?

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  init() {}

  /// Creates the record accompanying a freshly minted token.
  init(
    id: UUID? = nil,
    jti: UUID,
    resourceID: Resource.IDValue,
    label: String,
    expiresAt: Date,
    revokedAt: Date? = nil,
  ) {
    self.id = id
    self.jti = jti
    $resource.id = resourceID
    self.label = label
    self.expiresAt = expiresAt
    self.revokedAt = revokedAt
  }

  /// Whether the token is still usable, ignoring expiry — the signature already enforces that.
  var isLive: Bool {
    revokedAt == nil
  }
}
