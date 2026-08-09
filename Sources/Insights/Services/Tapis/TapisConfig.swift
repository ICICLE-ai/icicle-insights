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

  init(baseURL: String, tenant: String, admin: TapisAdmin) {
    self.baseURL =
      baseURL.hasSuffix("/")
      ? String(baseURL.dropLast())
      : baseURL
    self.tenant = tenant
    self.admin = admin
  }

  /// Base endpoint for user-scoped Tapis Vault secret operations.
  var vaultBaseURL: String {
    "\(baseURL)/security/vault/secret"
  }

  // var authBaseURL: String {
  //     // TODO: Write the correct base
  //     "\(baseURL)/auth-placeholder"
  // }

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
