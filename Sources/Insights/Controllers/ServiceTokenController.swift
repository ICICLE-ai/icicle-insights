import Fluent
import Vapor
import VaporToOpenAPI

/// Mints, lists, and revokes the webhook tokens deployed services use to report their metrics.
///
/// Admin-only throughout. Minting over HTTP is a deliberate reversal of the original design,
/// which kept credential creation off the network entirely; it holds here because these tokens
/// are narrow — one resource, one route, expiring — so an attacker who already holds admin gains
/// nothing by minting one that they could not do directly.
struct ServiceTokenController: RouteCollection {
  /// Mounts token administration under `/service-tokens`.
  func boot(routes: any RoutesBuilder) throws {
    let tokens = routes.grouped("service-tokens").grouped(Require.admin)

    tokens.get(use: index)
      .openAPI(
        tags: "Service Tokens",
        summary: "List webhook tokens",
        response: .type([ServiceToken.Public].self),
        auth: .bearer()
      )
    tokens.post(use: create)
      .openAPI(
        tags: "Service Tokens",
        summary: "Mint a webhook token",
        body: .type(ServiceToken.Create.self),
        response: .type(ServiceToken.Minted.self),
        statusCode: 201,
        auth: .bearer()
      )
    // Revoke rather than delete: the row is the audit trail of what was issued and when it
    // stopped working, so it outlives the credential.
    tokens.post(":tokenID", "revoke", use: revoke)
      .openAPI(
        tags: "Service Tokens",
        summary: "Revoke a webhook token",
        response: .type(ServiceToken.Public.self),
        auth: .bearer()
      )
    // Rotation is additive — the previous key stays registered — so this is safe to call from
    // the dashboard without taking every deployed service offline.
    tokens.post("rotate-key", use: rotateKey)
      .openAPI(
        tags: "Service Tokens",
        summary: "Rotate the signing key",
        response: .type(RotatedKey.self),
        auth: .bearer()
      )
  }

  /// The outcome of a rotation. Carries the new `kid`, never any key material.
  struct RotatedKey: Content {
    var activeKid: String
    var message: String
  }

  /// Builds the issuer bound to this request.
  private func issuer(for req: Request) -> ServiceTokenIssuer {
    ServiceTokenIssuer(
      db: req.db,
      keys: req.application.serviceTokenKeys,
      activeKid: req.application.activeSigningKid,
    )
  }

  @Sendable
  /// Lists every token ever issued, newest first, without their values.
  func index(req: Request) async throws -> [ServiceToken.Public] {
    try await issuer(for: req).list().map { $0.toPublic() }
  }

  @Sendable
  /// Mints a token and returns it once.
  func create(req: Request) async throws -> Response {
    let payload = try req.content.decode(ServiceToken.Create.self)

    let issued = try await issuer(for: req).mint(
      resourceID: payload.resourceID,
      label: payload.label,
      lifetimeInDays: payload.expiresInDays,
    )

    let minted = ServiceToken.Minted(
      token: issued.token,
      endpoint: "/api/resources/\(payload.resourceID)/metrics",
      serviceToken: issued.record.toPublic(),
    )

    return try await minted.encodeResponse(status: .created, for: req)
  }

  @Sendable
  /// Withdraws a token. Effective on its next request, with no restart.
  func revoke(req: Request) async throws -> ServiceToken.Public {
    guard let id = req.parameters.get("tokenID", as: UUID.self) else {
      throw Abort(.badRequest, reason: "'tokenID' must be a UUID.")
    }

    guard let record = try await issuer(for: req).revoke(id: id) else {
      throw Abort(.notFound)
    }

    return record.toPublic()
  }

  @Sendable
  /// Adds a new signing key and makes it active, without a restart.
  ///
  /// Previously issued tokens keep verifying: the retired key stays registered on the live
  /// collection until tokens signed with it have expired.
  func rotateKey(req: Request) async throws -> RotatedKey {
    let kid = try await req.application.rotateServiceTokenKey(using: req.application.secrets)

    return RotatedKey(
      activeKid: kid,
      message: "New tokens are signed with this key. Existing tokens keep working until expiry.",
    )
  }
}
