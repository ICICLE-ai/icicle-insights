import Fluent
import JWT
import Vapor

import struct Foundation.UUID

/// Claims carried by a webhook token.
///
/// The resource binding lives here rather than in a lookup because it must not be forgeable: a
/// service that edited its own resource id would be writing to someone else's series. Expiry is
/// here for the same reason. Only revocation needs a database, and only because a token already
/// issued cannot learn it was cancelled.
struct WebhookToken: JWTPayload {
  /// Distinguishes tokens this server minted from Tapis tokens and anything else.
  let issuer: IssuerClaim

  /// Unique per token, matched against a live ``ServiceToken`` row.
  let tokenID: IDClaim

  let issuedAt: IssuedAtClaim
  let expiration: ExpirationClaim

  /// The single resource this token may post metrics for.
  let resourceID: UUID

  enum CodingKeys: String, CodingKey {
    case issuer = "iss"
    case tokenID = "jti"
    case issuedAt = "iat"
    case expiration = "exp"
    case resourceID = "insights/resource_id"
  }

  /// Identifies this server as the issuer.
  static let issuerValue = "icicle-insights"

  func verify(using algorithm: some JWTAlgorithm) async throws {
    try expiration.verifyNotExpired()

    // A token signed with our key but issued by something else should never exist; if one ever
    // does, it is not ours to honour.
    guard issuer.value == Self.issuerValue else {
      throw JWTError.claimVerificationFailure(
        failedClaim: issuer,
        reason: "Unexpected issuer"
      )
    }
  }
}
