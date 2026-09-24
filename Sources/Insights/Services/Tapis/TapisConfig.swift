import Vapor

/// Credentials used to authenticate service-level Tapis requests.
struct TapisAdmin: Sendable {
  let name: Secret
  let token: Secret

  init(name: String, token: String) {
    self.name = Secret(name)
    self.token = Secret(token)
  }
}

/// Tenant-specific endpoints and credentials required by the Tapis client.
struct TapisConfig: Sendable {
  let baseURL: String
  let admin: TapisAdmin
  let tenant: String

  /// When `TAPIS_TOKEN` stops working, read from its own `exp` claim. Nil when the value is not
  /// a JWT carrying one, like CI's placeholder.
  ///
  /// The token is a static environment variable, and when it lapses every vault read fails and
  /// collection stops for every account at once. Nothing refreshes it, so the only defence is
  /// knowing the date in advance: it is logged at boot and `WarnExpiringTapisToken` alerts ahead
  /// of it.
  let tokenExpiry: Date?

  init(baseURL: String, tenant: String, admin: TapisAdmin) {
    self.baseURL =
      baseURL.hasSuffix("/")
      ? String(baseURL.dropLast())
      : baseURL
    self.tenant = tenant
    self.admin = admin
    self.tokenExpiry = Self.expiry(ofJWT: admin.token.getSecretValue())
  }

  /// Reads the `exp` claim of a JWT **without verifying its signature**, or nil when the value
  /// is not a three-part JWT whose payload carries a numeric `exp`.
  ///
  /// Unverified on purpose, and safe only because of what the answer is used for. This is this
  /// deployment's own configured credential, not something a caller presented, and the date
  /// only schedules a warning. It grants nothing and gates nothing. A forged `exp` could at worst
  /// move a reminder about a token the operator set themselves, while verifying would need the
  /// tenant key, which `.testing` never fetches and which a boot must not depend on just to log.
  ///
  /// Never throws, and never logs the token: a value that does not parse is simply not a JWT.
  static func expiry(ofJWT token: String) -> Date? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }

    // base64url differs from base64 in two characters and omits the padding `Data` requires.
    var encoded =
      String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)

    struct Claims: Decodable {
      let exp: Double?
    }

    guard
      let data = Data(base64Encoded: encoded),
      let exp = (try? JSONDecoder().decode(Claims.self, from: data))?.exp
    else {
      return nil
    }

    return Date(timeIntervalSince1970: exp)
  }

  /// Base endpoint for user-scoped Tapis Vault secret operations.
  var vaultBaseURL: String {
    "\(baseURL)/security/vault/secret"
  }

  /// Base endpoint for Tapis OAuth2 operations.
  var authBaseURL: String {
    "\(baseURL)/oauth2"
  }

  /// Base endpoint for tenant metadata, whose `public_key` verifies caller tokens.
  var tenantsBaseURL: String {
    "\(baseURL)/tenants"
  }

  /// Loads required Tapis settings from the process environment.
  /// - Throws: ``ConfigError`` when any required value is absent.
  static func fromEnvironment() throws -> TapisConfig {
    guard let baseURL = Environment.get("TAPIS_BASE_URL") else {
      throw ConfigError.missing("TAPIS_BASE_URL")
    }
    guard let token = Environment.get("TAPIS_TOKEN") else {
      throw ConfigError.missing("TAPIS_TOKEN")
    }

    guard let user = Environment.get("TAPIS_USER") else {
      throw ConfigError.missing("TAPIS_USER")
    }

    guard let tenant = Environment.get("TAPIS_TENANT") else {
      throw ConfigError.missing("TAPIS_TENANT")
    }

    let admin = TapisAdmin(name: user, token: token)
    return .init(baseURL: baseURL, tenant: tenant, admin: admin)
  }
}
