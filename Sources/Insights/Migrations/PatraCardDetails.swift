import Fluent

/// Adds the descriptive half of a Patra card to `patra_cards`: what the model or dataset is, who
/// made it, under what license, and how it scored — the fields a "Models" gallery shows.
///
/// Every column is nullable, and not only because the table already has rows: Patra itself
/// leaves most of these null on some live card (in September 2026, `license` on 9 of 38 model
/// cards, `test_accuracy` on 8, `size` and `format` on two of six datasheets), so null is a real
/// value here, not a placeholder awaiting a backfill.
///
/// **No backfill, deliberately.** The values live only in Patra, and `SyncPatraCatalog` rewrites
/// every one of them on every sweep, existing cards included. Existing rows stay null until the
/// next catalog sweep fills them, which is at most one sweep after deploy — copying anything in
/// here would be a stale second source for data the sweep is about to overwrite anyway.
///
/// `description` and `keywords` use `.string`, which FluentPostgresDriver maps to `TEXT`, not a
/// bounded `VARCHAR`: a datasheet's DataCite description runs to paragraphs, and a length limit
/// would turn one long description into a failed sweep. `keywords` keeps the raw comma-separated
/// string Patra sends rather than a `TEXT[]`, so the column stays a faithful copy of the source
/// and the split into a list happens once, in the API projection.
///
/// Additive on top of `MetricDailyTotals`, like every migration after `FirstMigration`.
struct PatraCardDetails: AsyncMigration {
  /// Adds the thirteen descriptive columns.
  func prepare(on database: any Database) async throws {
    try await database.schema("patra_cards")
      .field("description", .string)
      .field("author", .string)
      .field("category", .string)
      .field("license", .string)
      .field("framework", .string)
      .field("model_type", .string)
      .field("input_type", .string)
      .field("accuracy", .double)
      .field("keywords", .string)
      .field("is_gated", .bool)
      .field("size", .string)
      .field("format", .string)
      .field("publication_year", .int)
      .update()
  }

  /// Drops the descriptive columns. Nothing is lost that the next sweep after a re-migration
  /// cannot fetch again from Patra.
  func revert(on database: any Database) async throws {
    try await database.schema("patra_cards")
      .deleteField("description")
      .deleteField("author")
      .deleteField("category")
      .deleteField("license")
      .deleteField("framework")
      .deleteField("model_type")
      .deleteField("input_type")
      .deleteField("accuracy")
      .deleteField("keywords")
      .deleteField("is_gated")
      .deleteField("size")
      .deleteField("format")
      .deleteField("publication_year")
      .update()
  }
}
