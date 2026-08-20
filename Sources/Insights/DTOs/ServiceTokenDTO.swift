import Fluent
import Vapor
import VaporToOpenAPI

import struct Foundation.Date
import struct Foundation.UUID

extension ServiceToken {
  /// Request body for minting a webhook token.
  struct Create: Content, WithExample {
    /// Resource the token will be allowed to post metrics for.
    var resourceID: Resource.IDValue
    /// Deployment name this token identifies, e.g. `prod-inference`.
    var label: String
    /// Days until expiry. Defaults to 90 when omitted.
    var expiresInDays: Int?

    enum CodingKeys: String, CodingKey {
      case resourceID, label, expiresInDays
    }

    static let example = Create(
      resourceID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
      label: "prod-inference",
      expiresInDays: 90,
    )
  }

  /// Token metadata. Never carries the credential itself.
  struct Public: Content {
    var id: UUID?
    /// Matches the `jti` claim of the issued token.
    var jti: UUID?
    /// Resource this token may write to.
    var resourceID: Resource.IDValue?
    /// Deployment name.
    var label: String?
    var expiresAt: Date?
    /// Set once the token has been withdrawn.
    var revokedAt: Date?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, jti, resourceID, label, expiresAt, revokedAt, createdAt
    }
  }

  /// The response to a successful mint — **the only place the token is ever returned.**
  ///
  /// Nothing persists the value and no route can read it back, so a lost token means revoking
  /// and reissuing rather than looking it up.
  struct Minted: Content {
    /// The signed JWT. Shown once.
    var token: String
    /// Ready-to-paste endpoint for the deployed service.
    var endpoint: String
    /// Metadata for the record just created.
    var serviceToken: Public
  }

  /// Projects loaded model fields into the public API shape.
  func toPublic() -> Public {
    .init(
      id: id,
      jti: $jti.value,
      resourceID: $resource.id,
      label: $label.value,
      expiresAt: $expiresAt.value,
      revokedAt: revokedAt,
      createdAt: createdAt,
    )
  }
}
