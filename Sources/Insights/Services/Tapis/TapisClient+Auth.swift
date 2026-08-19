import Vapor

extension TapisClient {
  /// Fetches the tenant's RSA public key, which verifies caller tokens locally.
  ///
  /// Called once at boot rather than per request. Pinning a PEM in source turns a Tapis key
  /// rotation into every request failing 401 with nothing in the log explaining why; fetching
  /// it here turns a rotation into a restart.
  func getTenantPublicKey() async throws -> String {
    // Deliberately unauthenticated: tenant metadata is public, and the service token has no
    // business being spent on it.
    normalizePEM(try await getTenant().publicKey)
  }

  /// Re-wraps a PEM body at 64 characters.
  ///
  /// Tapis returns the base64 as a single unwrapped line. RFC 7468 requires 64-character lines
  /// and SwiftASN1 enforces it, so the key Tapis publishes cannot be parsed as it arrives —
  /// `Insecure.RSA.PublicKey(pem:)` throws `invalidPEMDocument: incorrect line lengths`. The
  /// bytes are fine; only the formatting is not.
  private func normalizePEM(_ pem: String) -> String {
    let lines = pem.split(whereSeparator: \.isNewline).map(String.init)

    guard
      let header = lines.first, header.hasPrefix("-----BEGIN"),
      let footer = lines.last, footer.hasPrefix("-----END")
    else {
      return pem
    }

    let body = lines.dropFirst().dropLast().joined()
    var wrapped: [String] = []
    var index = body.startIndex

    while index < body.endIndex {
      let end = body.index(index, offsetBy: 64, limitedBy: body.endIndex) ?? body.endIndex
      wrapped.append(String(body[index..<end]))
      index = end
    }

    return ([header] + wrapped + [footer]).joined(separator: "\n")
  }

  /// Fetches the tenant record.
  private func getTenant() async throws -> TapisTenantResponse.Result {
    let response = try await client.get(URI(string: "\(config.tenantsBaseURL)/\(config.tenant)"))

    guard response.status == .ok else {
      throw TapisClientError.requestFailed(status: response.status)
    }

    do {
      return try response.content.decode(TapisTenantResponse.self).result
    } catch {
      throw TapisClientError.invalidResponse
    }
  }

  /// Resolves the username behind a caller's Tapis token.
  ///
  /// Not on the request path — ``TapisAuthenticator`` verifies tokens locally against the
  /// tenant key, with no round trip. This exists for the Tapis login flow, which needs to
  /// identify a token before anything else has looked at it.
  func getUserInfo(_ token: Secret) async throws -> String {
    let uri = URI(string: "\(config.authBaseURL)/userinfo")

    let response = try await client.get(uri) { req in
      req.headers.add(
        name: "X-Tapis-Token",
        value: token.getSecretValue()
      )
    }

    guard response.status == .ok else {
      throw TapisClientError.requestFailed(status: response.status)
    }

    let payload: TapisGetUserInfoResponse

    do {
      payload = try response.content.decode(TapisGetUserInfoResponse.self)
    } catch {
      throw TapisClientError.invalidResponse
    }

    return payload.result.username
  }
}

/// Tenant metadata. Only `public_key` is modelled; the response carries considerably more.
///
/// Discovery via `/v3/oauth2/.well-known/oauth-authorization-server` was tried and abandoned:
/// that document's `jwks_uri` points back at *this* endpoint rather than to a key set, so there
/// are no `kid`-addressable keys to route between. One tenant, one key.
struct TapisTenantResponse: Content {
  struct Result: Content {
    /// PEM-encoded RSA public key the tenant signs its tokens with.
    let publicKey: String

    enum CodingKeys: String, CodingKey {
      case publicKey = "public_key"
    }
  }

  let result: Result
}

struct TapisGetUserInfoResponse: Content {
  struct Result: Content {
    let username: String
  }

  let result: Result
}
