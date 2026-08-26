import Fluent
import FluentSQL
import SQLKit

/// Adds the collection history the failure backoff reads, and brings any over-long GitHub cadence
/// inside the new cap.
///
/// Additive on top of `RecurringCollection`, which is already applied to deployed databases.
struct CollectionBackoff: AsyncMigration {
  /// Adds the history columns, backfills `last_collected_at` from real collection evidence, and
  /// clamps GitHub cadences to the new maximum.
  func prepare(on database: any Database) async throws {
    try await database.schema("resources")
      .field("last_collected_at", .datetime)
      .field("stall_notified_at", .datetime)
      .update()

    // `stall_notified_at` stays NULL for every existing row — there is no prior outage to
    // remember, so "never notified" is simply true. `last_collected_at` gets backfilled below
    // instead of being left NULL: without it, every existing resource reads as never having
    // collected, which trips the retention-window alert on its very first transient failure and
    // starts its backoff at the twelve-hour ceiling instead of the one-hour floor.

    guard let sql = database as? any SQLDatabase else { return }
    try await Self.backfillLastCollectedAt(on: sql)
    try await Self.clampGitHubCadences(on: sql)
  }

  /// Backfills `last_collected_at` for existing rows from the newest metric ever recorded for
  /// them.
  ///
  /// A `static func` for the same reason as ``clampGitHubCadences(on:)``: a test can drive it
  /// directly without re-running `prepare` against an already-migrated database.
  ///
  /// `max(metrics.recorded_at)` is honest where `now()` would not be: it is the timestamp of a
  /// reading that actually exists, evidence a collection genuinely succeeded at that moment. A
  /// resource with no metrics at all is left NULL on purpose — nothing has ever collected it, and
  /// no timestamp would be true.
  static func backfillLastCollectedAt(on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      UPDATE resources r
      SET last_collected_at = m.last
      FROM (SELECT resource_id, max(recorded_at) AS last FROM metrics GROUP BY resource_id) m
      WHERE m.resource_id = r.id
      """
    ).run()
  }

  /// Lowers every GitHub resource above the new 7-day cap down to it.
  ///
  /// A `static func` rather than inline in `prepare` so a test can drive it directly: migrations
  /// run once at application boot, and re-invoking `prepare` against an already-migrated test
  /// database would fail on the `.field()` calls for columns that already exist. Nothing in this
  /// repository seeds a resource above the cap, so this is defensive — it exists for deployed
  /// databases, where the old 14-day ceiling is exactly what such a row would carry.
  static func clampGitHubCadences(on sql: any SQLDatabase) async throws {
    // GitHub's accepted cadence drops from 14 days to 7, because at 14 the sweep interval equals
    // the traffic retention window and there is no headroom for any delay at all.
    try await sql.raw(
      """
      UPDATE resources
      SET collection_interval_days = 7
      WHERE collection_interval_days > 7
        AND account_id IN (SELECT id FROM accounts WHERE platform = 'github')
      """
    ).run()
  }

  /// Removes the history columns.
  ///
  /// One-way with respect to the cadence clamp: the original values are not recorded anywhere, so
  /// a revert cannot restore them. Reverting leaves every clamped resource at 7 days, which is a
  /// valid cadence under either cap.
  func revert(on database: any Database) async throws {
    try await database.schema("resources")
      .deleteField("last_collected_at")
      .deleteField("stall_notified_at")
      .update()
  }
}
