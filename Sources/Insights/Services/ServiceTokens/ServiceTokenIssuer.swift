import Fluent
import JWT
import Vapor

import struct Foundation.Date
import struct Foundation.UUID

/// Mints, lists, and revokes webhook tokens.
///
/// The single home for all three, so a token created from the CLI and one created from the
/// dashboard cannot drift apart: `ServiceTokenController` and `ServiceTokenCommand` are both
/// thin wrappers over this.
struct ServiceTokenIssuer: Sendable {
  let db: any Database
  let keys: JWTKeyCollection
  /// The `kid` to sign with. Retired keys stay registered on `keys` for verification, so tokens
  /// issued before a rotation keep working until they expire.
  let activeKid: String

  /// Long enough that reissuing is rare, short enough that a forgotten deployment's token
  /// eventually lapses on its own.
  static let defaultLifetimeInDays = 90

  /// A freshly minted token and the record that makes it revocable.
  ///
  /// `token` is returned exactly once, here. Nothing persists it, and no route can read it back.
  struct Issued: Sendable {
    let token: String
    let record: ServiceToken
  }

  /// Issues a token bound to one resource.
  ///
  /// Any live token already held by that resource is revoked in the same transaction, so a
  /// resource never has two working credentials and a replaced token cannot be left behind.
  ///
  /// - Throws: `Abort(.badRequest)` when the resource does not exist, is not a service, or the
  ///   label is blank.
  func mint(
    resourceID: Resource.IDValue,
    label: String,
    lifetimeInDays: Int? = nil,
  ) async throws -> Issued {
    // Empty means the application booted without a keyset — see `installEmptyServiceTokenKeys`.
    // Checked here rather than left to the signer, which would fail on an unregistered `kid` with
    // an error that says nothing about the missing setup step.
    guard !activeKid.isEmpty else {
      throw Abort(
        .serviceUnavailable,
        reason: "No signing keyset. Run `service-token init-key`, then restart.",
      )
    }

    let label = try requireNonBlank(label, "label")
    let days = try requireInRange(
      lifetimeInDays ?? Self.defaultLifetimeInDays, 1...365, "expiresInDays")

    guard let resource = try await Resource.find(resourceID, on: db) else {
      throw Abort(.badRequest, reason: "Resource with ID: \(resourceID), not found.")
    }
    guard resource.type == .service else {
      throw Abort(
        .badRequest,
        reason: "Service tokens can only be minted for resources of type 'service'.",
      )
    }

    let jti = UUID()
    let expiresAt = Date().addingTimeInterval(Double(days) * 86_400)

    let token = try await keys.sign(
      WebhookToken(
        issuer: .init(value: WebhookToken.issuerValue),
        tokenID: .init(value: jti.uuidString),
        issuedAt: .init(value: Date()),
        expiration: .init(value: expiresAt),
        resourceID: resourceID,
      ),
      kid: .init(string: activeKid),
    )

    let record = ServiceToken(
      jti: jti,
      resourceID: resourceID,
      label: label,
      expiresAt: expiresAt,
    )

    // Revoking the predecessor and creating the replacement must not half-happen: one leaves a
    // resource with no working token, the other leaves it with two.
    try await db.transaction { db in
      let superseded = try await ServiceToken.query(on: db)
        .filter(\.$resource.$id == resourceID)
        .filter(\.$revokedAt == nil)
        .all()

      let now = Date()
      for token in superseded {
        token.revokedAt = now
        try await token.save(on: db)
      }

      try await record.create(on: db)
    }

    return Issued(token: token, record: record)
  }

  /// Withdraws a token. Takes effect on its next request — the lookup is live, not cached.
  ///
  /// - Returns: The revoked record, or nil when no such token exists.
  @discardableResult
  func revoke(id: ServiceToken.IDValue) async throws -> ServiceToken? {
    guard let record = try await ServiceToken.find(id, on: db) else { return nil }

    // Revoking twice is not an error, but it should not move the timestamp: the first one is
    // when access actually stopped.
    if record.revokedAt == nil {
      record.revokedAt = Date()
      try await record.save(on: db)
    }

    return record
  }

  /// Withdraws a token by its `jti`, which is what the CLI and the token itself expose.
  @discardableResult
  func revoke(jti: UUID) async throws -> ServiceToken? {
    guard
      let record = try await ServiceToken.query(on: db).filter(\.$jti == jti).first()
    else {
      return nil
    }

    return try await revoke(id: try record.requireID())
  }

  /// Every token ever issued, newest first. Revoked and expired records are kept deliberately —
  /// they are the audit trail of what was issued and when it stopped working.
  func list() async throws -> [ServiceToken] {
    try await ServiceToken.query(on: db)
      .sort(\.$createdAt, .descending)
      .all()
  }
}
