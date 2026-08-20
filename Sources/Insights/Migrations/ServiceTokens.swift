import Fluent
import FluentSQL
import SQLKit

/// Adds storage for webhook token records. Separate from `FirstMigration` because that one is
/// already applied to deployed databases; this is purely additive on top of it.
struct ServiceTokens: AsyncMigration {
  /// Creates the token table and the index the request path depends on.
  func prepare(on database: any Database) async throws {
    try await database.schema("service_tokens")
      .id()
      .field("jti", .uuid, .required)
      .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
      .field("label", .string, .required)
      .field("expires_at", .datetime, .required)
      .field("revoked_at", .datetime)
      .field("created_at", .datetime)
      // Two tokens sharing a `jti` would make the request-path lookup ambiguous.
      .unique(on: "jti")
      .create()

    // Every authenticated webhook request resolves a token by `jti`, so this is on the hot path
    // rather than a reporting convenience.
    if let sql = database as? any SQLDatabase {
      try await sql.raw(
        """
        CREATE INDEX idx_service_tokens_jti
        ON service_tokens (jti)
        """
      ).run()
    }
  }

  /// Drops the index and the table.
  func revert(on database: any Database) async throws {
    if let sql = database as? any SQLDatabase {
      try await sql.raw("DROP INDEX IF EXISTS idx_service_tokens_jti").run()
    }

    try await database.schema("service_tokens").delete()
  }
}
