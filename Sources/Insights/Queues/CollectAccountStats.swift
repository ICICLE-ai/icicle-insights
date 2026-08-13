import Fluent
import Queues
import Vapor

/// Monthly sweep for account-level figures.
///
/// Separate from `CollectDueResources` because the unit differs: folding it in would dispatch
/// once per resource the account owns. Followers have no retention window, so a fixed monthly
/// cadence suffices and `Account` needs no interval column.
struct CollectAccountStats: AsyncScheduledJob {
  /// Dispatches one organization-statistics job for every GitHub account.
  func run(context: QueueContext) async throws {
    let accounts = try await Account.query(on: context.application.db)
      .filter(\.$platform == .github)
      .all()

    guard !accounts.isEmpty else { return }

    let queue = context.queues(.metrics)

    for account in accounts {
      let id = try account.requireID()
      do {
        try await queue.dispatch(
          SyncGitHubOrgStats.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
      } catch {
        context.logger.report(error: error)
      }
    }
  }
}
