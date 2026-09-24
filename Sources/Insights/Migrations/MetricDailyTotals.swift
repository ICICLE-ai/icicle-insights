import Fluent
import FluentSQL
import SQLKit

/// Adds `metric_daily_totals`: one snapshot per resource, all-time type, and UTC day of the
/// running total as it stood at that day's last write.
///
/// Lifetime metrics had no history at all. An all-time total is a single row updated in place,
/// and `Metric.recordedAt` is stamped on create only, so the row says what the total is now and
/// nothing about what it was last month. Every write of a total now also upserts today's row
/// here, in the same transaction, which is what the insights endpoints chart lifetime trends from.
///
/// **No backfill, deliberately.** Past totals were overwritten and never recorded anywhere, so
/// nothing exists to reconstruct them from: summing old `clones` readings re-counts overlapping
/// windows, and the Hub's lifetime downloads were only ever stored as the latest figure. A guessed
/// history would be indistinguishable from a real one. Lifetime history therefore starts on the
/// day this migration is deployed, and the API reports an empty series before then rather than an
/// invented one.
///
/// Additive on top of `PatraPlatform`, like every migration after `FirstMigration`.
struct MetricDailyTotals: AsyncMigration {
  /// Creates the table, keyed so each resource, type, and day holds exactly one row.
  func prepare(on database: any Database) async throws {
    let metricType = try await database.enum("metric_type").read()

    // `ON DELETE CASCADE` to match `metrics` and `metric_watermarks`: the snapshots are derived
    // from a resource's totals and mean nothing without it. Resources are soft-deleted in
    // practice, so this only applies to a hard delete; the read queries filter soft-deleted
    // resources themselves.
    //
    // The unique constraint is what the upsert's `ON CONFLICT (resource_id, type, day)` names,
    // and its index also serves the read side, which looks up by resource and type up to a day.
    try await database.schema("metric_daily_totals")
      .id()
      .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
      .field("type", metricType, .required)
      .field("day", .date, .required)
      .field("reading", .double, .required)
      .field("created_at", .datetime)
      .field("updated_at", .datetime)
      .unique(on: "resource_id", "type", "day")
      .create()
  }

  /// Drops the table. The history in it is lost; it cannot be rebuilt from anything else.
  func revert(on database: any Database) async throws {
    try await database.schema("metric_daily_totals").delete()
  }
}
