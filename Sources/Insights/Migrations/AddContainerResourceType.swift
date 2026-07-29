import Fluent
import SQLKit

/// Adds container images as a resource type without rebuilding the PostgreSQL enum or
/// touching any existing resource rows. GHCR artifacts were previously typed `package`,
/// which conflated them with npm packages; `image` was already taken by graphics.
struct AddContainerResourceType: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw UnsupportedDatabase()
        }

        try await sql.raw("""
        ALTER TYPE resource_type ADD VALUE IF NOT EXISTS 'container'
        """).run()
    }

    /// PostgreSQL cannot remove an enum value safely in place. Leaving an unused
    /// value behind preserves data and remains compatible with the previous schema.
    func revert(on _: any Database) async throws {}
}
