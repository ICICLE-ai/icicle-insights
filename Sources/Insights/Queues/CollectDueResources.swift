import Fluent
import Foundation
import Queues
import Vapor

/// Hourly sweep dispatching a sync for every resource now due, then booking the next one.
///
/// Hourly is the schedule's resolution, not the cadence: each resource carries its own
/// interval, so resources on different cadences need no separate schedules.
struct CollectDueResources: AsyncScheduledJob {
  func run(context: QueueContext) async throws {
    let now = Date()
    let due = try await Resource.query(on: context.application.db)
      .filter(\.$nextCollectionAt <= now)
      .with(\.$account)
      .all()

    guard !due.isEmpty else { return }

    context.logger.info("Collecting due resources", metadata: ["count": .string("\(due.count)")])

    let queue = context.queues(.metrics)

    for resource in due {
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
