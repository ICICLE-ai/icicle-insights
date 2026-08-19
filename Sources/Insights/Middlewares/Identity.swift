import Vapor

import struct Foundation.UUID

/// A human on the dashboard, authenticated by their Tapis token.
///
/// Being authenticated says nothing about what they may do — ``Require`` answers that. Admin
/// status is resolved once during authentication and carried here rather than looked up by
/// `Require`, whose predicate is synchronous and so cannot reach the database.
struct TapisUser: Authenticatable, Sendable {
  let username: String
  let tenant: String

  /// True for the root admin, or anyone in the `admins` table at the time of this request.
  let isAdmin: Bool
}

/// A deployed ICICLE service, authenticated by the webhook token it was issued.
///
/// Never an admin, and never broadly permitted: it may post metrics for exactly one resource.
/// Which one is fixed at mint time and carried in the token's signature, so it cannot be
/// widened by the caller.
struct ServiceClient: Authenticatable, Sendable {
  /// The token's `jti`, matched against a live ``ServiceToken`` row on every request.
  let jti: UUID

  /// The single resource this caller may write to.
  let resourceID: Resource.IDValue

  /// Operator-chosen deployment name, for logs and request attribution.
  let label: String
}
