import Fluent
import SQLKit

/// Adds GitHub Container Registry as an account platform without rebuilding the
/// PostgreSQL enum or touching any existing account rows.
struct AddGHCRPlatform: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw UnsupportedDatabase()
        }

        try await sql.raw("""
        ALTER TYPE platform ADD VALUE IF NOT EXISTS 'ghcr'
        """).run()
    }

    /// PostgreSQL cannot remove an enum value safely in place. Leaving an unused
    /// value behind preserves data and remains compatible with the previous schema.
    func revert(on _: any Database) async throws {}
}
