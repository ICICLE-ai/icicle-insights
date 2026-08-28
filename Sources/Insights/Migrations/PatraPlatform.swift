import Fluent

/// Adds Patra as a collected platform: the `patra`, `agent`, and `deployments` enum values, and
/// `patra_cards`, the table that records the registry's own card identifiers and provenance
/// links.
///
/// Safe as one migration: `patra_cards` references no enum value added here, so nothing in this
/// transaction depends on something the same transaction is still creating. Additive on top of
/// `CollectionBackoff`, which is already applied to deployed databases.
struct PatraPlatform: AsyncMigration {
  /// Adds the three enum values and creates `patra_cards`.
  func prepare(on database: any Database) async throws {
    _ = try await database.enum("platform").case("patra").update()
    _ = try await database.enum("resource_type").case("agent").update()
    _ = try await database.enum("metric_type").case("deployments").update()

    try await database.schema("patra_cards")
      .id()
      .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
      .field("card_uuid", .string, .required)
      .field("version", .string)
      .field("card_updated_at", .datetime)
      .field("source_url", .string)
      .field("hub_resource_id", .uuid, .references("resources", "id", onDelete: .setNull))
      .field(
        "repository_resource_id", .uuid, .references("resources", "id", onDelete: .setNull)
      )
      .field("training_datasheet_uuid", .string)
      .field("created_at", .datetime)
      .unique(on: "card_uuid")
      .create()

    // No partial index for soft deletes: a deleted resource keeps its card rows, so a later sync
    // still finds the uuid, sees `deleted_at` on the resource it points to, and skips it there.
  }

  /// Drops `patra_cards` only.
  ///
  /// One-way with respect to the enum values: PostgreSQL has no `ALTER TYPE … DROP VALUE`, and
  /// rebuilding the type would mean rewriting `accounts.platform`, `resources.type`, and
  /// `metric_watermarks.type` to drop a column that references it. Reverting leaves `patra`,
  /// `agent`, and `deployments` as valid-but-unused enum values, which is harmless — nothing
  /// selects them once this table is gone.
  func revert(on database: any Database) async throws {
    try await database.schema("patra_cards").delete()
  }
}
