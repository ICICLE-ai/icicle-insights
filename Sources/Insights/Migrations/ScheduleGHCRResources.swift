import Fluent
import FluentSQL
import SQLKit

/// Books a first collection for every active GHCR resource that has no due date.
///
/// `CollectDueResources` selects on `next_collection_at <= now`, which never matches NULL, so a
/// resource without a date is never swept. GHCR resources ended up that way in production: they
/// were written by the July 2026 snapshot, which inserted rows without a date, at a time when GHCR
/// had no collector and nothing would have used one. The collector now exists, and every one of
/// those containers still reads *Not scheduled*, so no pull has been collected for any of them.
///
/// GHCR only, deliberately. npm and PyPI rows are in the same state, and are left in it: there is
/// no plan to collect either, because their download counts cannot tell a person from a CI runner
/// or a mirror refreshing its cache. Giving them a date would only make the console claim a
/// collection that the dispatcher then skips.
///
/// `RecurringCollection` ran the same backfill for every platform, but it only reaches rows that
/// existed when it ran; the snapshot inserted its rows afterwards.
struct ScheduleGHCRResources: AsyncMigration {
  /// Makes every unscheduled, active GHCR resource due now.
  func prepare(on database: any Database) async throws {
    guard let sql = database as? any SQLDatabase else { return }
    try await Self.scheduleUnscheduledGHCRResources(on: sql)
  }

  /// Nothing to undo. Which rows were NULL before is not recorded, and clearing dates that later
  /// collections have since rebooked would strand those resources again.
  func revert(on database: any Database) async throws {}

  /// Due now rather than spread over the week: the first sweep after a deploy then fetches every
  /// package page once, and each success books the next collection from its own completion time.
  ///
  /// Resources under a soft-deleted account are skipped. The sweep would only log them as orphans
  /// every hour, and the API already refuses to delete an account that still has resources.
  ///
  /// A `static func` so a test can drive it directly: `prepare` has already run once at app boot.
  static func scheduleUnscheduledGHCRResources(on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      UPDATE resources r
      SET next_collection_at = now()
      FROM accounts a
      WHERE a.id = r.account_id
        AND a.platform = 'ghcr'
        AND a.deleted_at IS NULL
        AND r.next_collection_at IS NULL
        AND r.deleted_at IS NULL
      """
    ).run()
  }
}
