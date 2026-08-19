import Fluent
import Vapor

extension Application {
  private struct RootAdminKey: StorageKey {
    typealias Value = String
  }

  /// The one username that is always an admin, regardless of what the `admins` table says.
  ///
  /// Break-glass, deliberately: the table is managed from the dashboard, and an accidental
  /// deletion of the last row would otherwise lock everyone out of the surface needed to fix it.
  /// This one cannot be removed through the API.
  var rootAdmin: String {
    get {
      guard let username = storage[RootAdminKey.self] else {
        fatalError("Root admin not configured — set app.rootAdmin in configure.swift")
      }
      return username
    }
    set { storage[RootAdminKey.self] = newValue }
  }

  /// Reads `ROOT_ADMIN_USERNAME`.
  ///
  /// - Throws: ``ConfigError`` when absent or blank. A boot failure is far easier to diagnose
  ///   than every write returning 403 in production.
  static func rootAdminFromEnvironment() throws -> String {
    guard let raw = Environment.get("ROOT_ADMIN_USERNAME") else {
      throw ConfigError.missing("ROOT_ADMIN_USERNAME")
    }

    let username = raw.trimmingCharacters(in: .whitespaces)

    guard !username.isEmpty else {
      throw ConfigError.unsupported(name: "ROOT_ADMIN_USERNAME", value: raw)
    }

    return username
  }
}

extension Request {
  /// Whether a Tapis username holds administrative access.
  ///
  /// Resolved during authentication rather than inside ``Require``, which holds a synchronous
  /// closure and so cannot reach the database. One indexed lookup per authenticated request,
  /// the same cost already accepted for the webhook token lookup.
  func isAdmin(_ username: String) async throws -> Bool {
    if username == application.rootAdmin { return true }

    return try await Admin.query(on: db)
      .filter(\.$username == username)
      .first() != nil
  }
}
