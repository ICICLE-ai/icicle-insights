import Fluent
import FluentSQL
import SQLKit

/// Adds per-resource collection scheduling and the watermarks that keep windowed metrics from
/// being counted twice. Separate from `FirstMigration` because that one is already applied to
/// deployed databases; this is purely additive on top of it.
struct RecurringCollection: AsyncMigration {
  func prepare(on database: any Database) async throws {
    try await database.schema("resources")
      .field("next_collection_at", .datetime)
      .field("collection_interval_days", .int, .required, .sql(.default(7)))
      .update()

    // Existing rows get a NULL due date, which the sweep's `<= now` filter never matches —
    // they would sit uncollected forever. Backfill as due so the first sweep picks them up.
    if let sql = database as? any SQLDatabase {
      try await sql.raw(
        """
        UPDATE resources
        SET next_collection_at = now()
        WHERE next_collection_at IS NULL AND deleted_at IS NULL
        """
      ).run()

      try await sql.raw(
        """
        CREATE INDEX idx_resources_next_collection
        ON resources (next_collection_at)
        """
      ).run()
    }

    let metricType = try await database.enum("metric_type").read()

    try await database.schema("metric_watermarks")
      .id()
      .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
      .field("type", metricType, .required)
      .field("counted_through", .datetime, .required)
      .field("created_at", .datetime)
      .field("updated_at", .datetime)
      .unique(on: "resource_id", "type")
      .create()
  }

  func revert(on database: any Database) async throws {
    try await database.schema("metric_watermarks").delete()

    if let sql = database as? any SQLDatabase {
      try await sql.raw("DROP INDEX IF EXISTS idx_resources_next_collection").run()
    }

    try await database.schema("resources")
      .deleteField("next_collection_at")
      .deleteField("collection_interval_days")
      .update()
  }
}
