import JWT
import Vapor

/// The claims a Tapis token carries.
///
/// Identity is read from here rather than from `/v3/oauth2/userinfo`, which does not return the
/// tenant. Tampering with any of these breaks the signature, so the claims are trustworthy only
/// *after* verification.
struct TapisToken: JWTPayload {
  let tenant: String
  let username: String
  let accountType: String
  let expiration: ExpirationClaim

  enum CodingKeys: String, CodingKey {
    case tenant = "tapis/tenant_id"
    case username = "tapis/username"
    case accountType = "tapis/account_type"
    case expiration = "exp"
  }

  func verify(using algorithm: some JWTAlgorithm) async throws {
    try expiration.verifyNotExpired()
  }
}

/// Authenticates a human by verifying their Tapis token against the tenant's public key.
///
/// Verification is local — the key is fetched once at boot — so there is no round trip to Tapis
/// on the request path, and a service API token presented here is never forwarded anywhere.
struct TapisAuthenticator: AsyncBearerAuthenticator {
  func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
    let token: TapisToken

    do {
      token = try await request.jwt.verify(bearer.token, as: TapisToken.self)
    } catch {
      // Not a Tapis token: a webhook token, an expired or forged JWT, or noise. Return quietly
      // rather than throwing — ServiceTokenAuthenticator still gets its turn, public reads still
      // work for anonymous callers, and `Require` decides the status at the end.
      //
      // Logged at debug because this path also swallows genuine misconfiguration: a rotated
      // tenant key, or a `kid` we never registered, looks identical to a garbage bearer value
      // and would otherwise be a silent 401 for every admin with nothing to diagnose from.
      request.logger.debug(
        "Bearer value did not verify as a Tapis token.",
        metadata: ["error": .string("\(error)")]
      )
      return
    }

    // A valid signature does not establish the tenant. Whether Tapis issues per-tenant signing
    // keys decides if this is redundant; it is one comparison and it is correct either way.
    guard token.tenant == request.application.tapisConfig.tenant else {
      // Notice, not debug: a properly signed token from the wrong tenant is either a
      // misconfigured `TAPIS_TENANT` on this side — in which case every admin is being refused
      // right now — or someone presenting another tenant's credential. Both are worth seeing.
      request.logger.notice(
        "Rejected a validly signed Tapis token from an unexpected tenant.",
        metadata: [
          "token_tenant": .string(token.tenant),
          "expected_tenant": .string(request.application.tapisConfig.tenant),
        ]
      )
      return
    }

    let isAdmin = try await request.isAdmin(token.username)

    request.auth.login(
      TapisUser(
        username: token.username,
        tenant: token.tenant,
        isAdmin: isAdmin,
      )
    )

    request.logger.debug(
      "Authenticated a Tapis user.",
      metadata: [
        "username": .string(token.username),
        "is_admin": .stringConvertible(isAdmin),
      ]
    )
  }
}
