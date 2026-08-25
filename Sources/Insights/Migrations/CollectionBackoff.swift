import Fluent
import FluentSQL
import SQLKit

/// Adds the collection history the failure backoff reads, and brings any over-long GitHub cadence
/// inside the new cap.
///
/// Additive on top of `RecurringCollection`, which is already applied to deployed databases.
struct CollectionBackoff: AsyncMigration {
  /// Adds the history columns and clamps GitHub cadences to the new maximum.
  func prepare(on database: any Database) async throws {
    try await database.schema("resources")
      .field("last_collected_at", .datetime)
      .field("stall_notified_at", .datetime)
      .update()

    // Both columns stay NULL for existing rows on purpose: a NULL `last_collected_at` means "no
    // success recorded", and the backoff falls back to `created_at`. Backfilling it with now()
    // would claim a success that never happened and suppress the data-loss alert for one full
    // retention window.

    guard let sql = database as? any SQLDatabase else { return }

    // GitHub's accepted cadence drops from 14 days to 7, because at 14 the sweep interval equals
    // the traffic retention window and there is no headroom for any delay at all. Nothing in the
    // repository seeds such a row, so this is defensive.
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
