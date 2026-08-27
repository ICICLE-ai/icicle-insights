import Fluent
import Queues
import Vapor

/// Daily sweep that keeps Patra's catalog current.
///
/// Separate from `CollectAccountStats` for the same reason that job is separate from
/// `CollectDueResources`: the unit differs. Followers move slowly enough that a fixed monthly
/// cadence suffices, but Patra is a live registry — new model cards and datasheets can appear at
/// any time — so folding this into the monthly sweep would leave newly published work
/// undiscovered for weeks. Daily is the cadence `SyncPatraCatalog` itself is written for; the job
/// pages the whole catalog on every run rather than tracking a due date per account.
struct CollectPatraCatalog: AsyncScheduledJob {
  /// Dispatches one catalog-discovery job for every Patra account.
  func run(context: QueueContext) async throws {
    await context.recordSchedulerHeartbeat(job: "CollectPatraCatalog")
    let accounts = try await Account.query(on: context.application.db)
      .filter(\.$platform == .patra)
      .all()

    guard !accounts.isEmpty else { return }

    let queue = context.queues(.metrics)

    for account in accounts {
      let id = try account.requireID()
      do {
        try await queue.dispatch(
          SyncPatraCatalog.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
      } catch {
        context.logger.report(error: error)
      }
    }
  }
}
