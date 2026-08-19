import Fluent
import FluentSQL
import SQLKit

/// Moves the admin allowlist out of the environment and into a table, so granting access stops
/// requiring a redeploy. Additive on top of the already-deployed schema.
struct Admins: AsyncMigration {
  /// Creates the admin table and the index the authenticator reads on every request.
  func prepare(on database: any Database) async throws {
    try await database.schema("admins")
      .id()
      .field("username", .string, .required)
      .field("added_by", .string, .required)
      .field("created_at", .datetime)
      .field("updated_at", .datetime)
      .field("deleted_at", .datetime)
      // Granting the same person twice would make the lookup ambiguous rather than idempotent.
      .unique(on: "username")
      .create()

    // Resolved once per authenticated request, so this is on the hot path.
    if let sql = database as? any SQLDatabase {
      try await sql.raw(
        """
        CREATE INDEX idx_admins_username
        ON admins (username)
        """
      ).run()
    }
  }

  /// Drops the index and the table.
  func revert(on database: any Database) async throws {
    if let sql = database as? any SQLDatabase {
      try await sql.raw("DROP INDEX IF EXISTS idx_admins_username").run()
    }

    try await database.schema("admins").delete()
  }
}
