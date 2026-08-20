import Fluent
import Foundation
import Queues
import Vapor

/// Builds the same queue context used by Vapor Queues' scheduled worker.
///
/// One-shot commands call scheduled jobs directly instead of starting a timer. Reusing the
/// application's queue configuration, logger, and event-loop group keeps dispatch behavior
/// identical to a clock-triggered run.
///
/// - Parameter application: The configured Vapor application running the command.
/// - Returns: A context whose queue name identifies the invocation as scheduled work.
private func scheduledQueueContext(for application: Application) -> QueueContext {
  QueueContext(
    queueName: QueueName(string: "scheduled"),
    configuration: application.queues.configuration,
    application: application,
    logger: application.logger,
    on: application.eventLoopGroup.any()
  )
}

/// Runs the resource due-date sweep once without changing its production schedule.
///
/// By default, only resources whose `nextCollectionAt` is due are dispatched. Pass `--force`
/// to reset every active resource's due date first. The dispatched sync jobs still execute on
/// the persistent `metrics` worker and retain their normal watermark protection.
struct CollectResourcesNowCommand: AsyncCommand {
  /// Command-line options accepted by ``CollectResourcesNowCommand``.
  struct Signature: CommandSignature {
    /// Whether every active resource should be made immediately eligible for collection.
    ///
    /// A forced run changes scheduling state: successfully dispatched resources book their
    /// next collection relative to the current time.
    @Flag(
      name: "force",
      help: "Mark every active resource due before dispatching collection jobs."
    )
    var force: Bool
  }

  /// A concise description displayed by Vapor's command-line help.
  var help: String {
    "Run the due-resource collection sweep immediately."
  }

  /// Selects eligible resources and dispatches their platform-specific sync jobs.
  ///
  /// - Parameters:
  ///   - context: Vapor's command context containing the configured application.
  ///   - signature: Parsed command-line options, including the optional force flag.
  /// - Throws: Database, queue, or platform-routing errors that prevent dispatch.
  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application

    if signature.force {
      let resources = try await Resource.query(on: application.db).all()
      let now = Date()

      for resource in resources {
        resource.nextCollectionAt = now
        try await resource.save(on: application.db)
      }

      application.logger.notice(
        "Marked all active resources due",
        metadata: ["count": .string("\(resources.count)")]
      )
    }

    try await CollectDueResources().run(context: scheduledQueueContext(for: application))
    application.logger.notice("Immediate resource collection sweep completed")
  }
}

/// Runs the account-level collection sweep once without changing its monthly schedule.
///
/// Every GitHub account is dispatched because account metrics do not carry resource-style due
/// dates. The command exits after enqueueing; the persistent `metrics` worker performs the API
/// requests and database writes.
struct CollectAccountsNowCommand: AsyncCommand {
  /// This command intentionally accepts no command-line options.
  struct Signature: CommandSignature {}

  /// A concise description displayed by Vapor's command-line help.
  var help: String {
    "Dispatch account-level collection jobs immediately."
  }

  /// Dispatches the registered account-level synchronization jobs.
  ///
  /// - Parameters:
  ///   - context: Vapor's command context containing the configured application.
  ///   - signature: The command's empty parsed signature.
  /// - Throws: Database or queue errors that prevent account jobs from being dispatched.
  func run(using context: CommandContext, signature: Signature) async throws {
    try await CollectAccountStats().run(
      context: scheduledQueueContext(for: context.application)
    )
    context.application.logger.notice("Immediate account collection sweep completed")
  }
}
