import Fluent
import FluentSQL
import SQLKit

struct FirstMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create Enums
        _ = try await database.enum("platform")
            .case("github")
            .case("huggingface")
            .case("npm")
            .case("pypi")
            .create()

        _ = try await database.enum("resource_type")
            .case("dataset")
            .case("image")
            .case("model")
            .case("package")
            .case("service")
            .create()

        _ = try await database.enum("metric_type")
            .case("clones")
            .case("downloads")
            .case("forks")
            .case("likes")
            .case("pulls")
            .case("stars")
            .case("subscribers")
            .case("views")
            .create()

        // Read enums from database to use in creating tables
        let platform = try await database.enum("platform").read()
        let resourceType = try await database.enum("resource_type").read()
        let metricType = try await database.enum("metric_type").read()

        // Create tables in order
        try await database.schema("accounts")
            .id()
            .field("name", .string, .required)
            .field("platform", platform, .required)
            .field("followers", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "name", "platform")
            .create()

        try await database.schema("vaults")
            .id()
            .field("name", .string, .required)
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("expires_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name", "account_id")
            .create()

        try await database.schema("resources")
            .id()
            .field("name", .string, .required)
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("type", resourceType, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "name", "account_id", "type")
            .create()

        try await database.schema("metrics")
            .id()
            .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
            .field("reading", .double, .required, .sql(.default(0.0)))
            .field("type", metricType, .required)
            .field("recorded_at", .datetime)
            .create()

        // Composite index for the chart query: filter by resource + type, sort by time.
        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
            CREATE INDEX idx_metrics_resource_type_time
            ON metrics (resource_id, type, recorded_at DESC)
            """).run()
        }

        try await database.schema("releases")
            .id()
            .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
            .field("version", .string, .required)
            .field("released_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        // Delete tables
        try await database.schema("releases").delete()
        try await database.schema("metrics").delete()
        try await database.schema("resources").delete()
        try await database.schema("vaults").delete()
        try await database.schema("accounts").delete()

        // Delete enums
        try await database.enum("metric_type").delete()
        try await database.enum("resource_type").delete()
        try await database.enum("platform").delete()
    }
}
