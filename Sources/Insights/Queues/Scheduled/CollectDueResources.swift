import Fluent
import Foundation
import Queues
import Vapor

/// Hourly sweep dispatching a sync for every resource now due, then booking the next one.
///
/// Hourly is the schedule's resolution, not the cadence: each resource carries its own
/// interval, so resources on different cadences need no separate schedules.
struct CollectDueResources: AsyncScheduledJob {
  /// Dispatches every currently due resource and advances successfully queued due dates.
  func run(context: QueueContext) async throws {
    await context.recordSchedulerHeartbeat(job: "CollectDueResources")
    let now = Date()

    // `withDeleted: true` on the account, then a skip below, rather than a join that filters on
    // `accounts.deleted_at IS NULL`. A plain eager load excludes a soft-deleted account and then
    // throws `missingParent` instead of answering nil, and because the whole due set is one
    // query, one orphaned resource used to fail every sweep and stop collection for everyone.
    //
    // A join was rejected for two reasons. The eager load after it is a second query, so an
    // account deleted between the two still throws, which is the very failure being fixed. And
    // it hides the orphan silently. Loading with `withDeleted` cannot throw for a soft-deleted
    // parent at all, since the foreign key guarantees the row exists, and the skip is logged.
    let due = try await Resource.query(on: context.application.db)
      .filter(\.$nextCollectionAt <= now)
      .with(\.$account, withDeleted: true)
      .all()

    guard !due.isEmpty else { return }

    context.logger.info("Collecting due resources", metadata: ["count": .string("\(due.count)")])

    let queue = context.queues(.metrics)

    for resource in due {
      guard !resource.accountIsDeleted else {
        // Neither dispatched nor re-booked. Advancing the due date would book a collection that
        // can never happen, and clearing it would lose the schedule if the account is restored,
        // which is only ever an undeleted row. Left due, a restored account resumes on the next
        // sweep. `AccountController.delete` now refuses this state, so an orphan is either older
        // than that guard or made by hand, and the hourly line is how it gets noticed.
        context.orphanSkipped(resource, job: "CollectDueResources")
        continue
      }

      do {
        try await queue.dispatchSync(
          for: resource,
          platform: resource.account.platform,
          logger: context.logger
        )
      } catch {
        // Keeps its due date, so the next sweep retries it rather than stranding the rest.
        context.logger.report(error: error)
        continue
      }

      resource.scheduleNextCollection(from: now)
      try await resource.save(on: context.application.db)
    }
  }
}
