import Logging
import Queues
import Vapor

import struct Foundation.Date

/// Retry budget a backup is dispatched with.
///
/// Two retries, 30 seconds and then 2 minutes later under `BackoffRetrying`, fewer than a sync's
/// three. What clears on its own here is a blip: a restarting database, a lock held through a
/// migration, a store answering 503. A credential or configuration fault will not be fixed in the
/// next eight minutes, and tomorrow's run is the natural next attempt.
let backupMaxRetryCount = 2

/// The queue payload for a backup.
struct DatabaseBackupRequest: Codable, Sendable {
  /// When the scheduler queued it, logged beside the result so a backlog on `metrics` shows up
  /// as the gap between this and the key's own timestamp.
  let requestedAt: Date
}

/// Dumps the database and uploads it, on the `metrics` worker.
///
/// A queued job rather than work done inline by the scheduler, for two reasons. The scheduler has
/// no retries, and a job gets `BackoffRetrying`'s. And the scheduler stays a clock that only
/// enqueues, as every other scheduled job here is, so a slow dump never delays an hourly sweep.
struct BackupDatabase: AsyncJob, BackoffRetrying {
  typealias Payload = DatabaseBackupRequest

  func dequeue(_ context: QueueContext, _ payload: DatabaseBackupRequest) async throws {
    guard let backup = context.application.databaseBackup else {
      // The scheduler had a bucket and this worker does not. Reported and then returned from,
      // not thrown: no retry can give this process an environment variable it was started
      // without, so throwing would only spend the retries rediscovering that.
      await context.reportBackupFailure(BackupError.notConfigured, job: Self.name)
      return
    }

    let receipt = try await backup.run(
      client: context.application.client, logger: context.logger)
    context.logger.debug(
      "Backup job finished.",
      metadata: [
        "key": .string(receipt.key),
        "requested_at": .string("\(payload.requestedAt)"),
      ]
    )
  }

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: DatabaseBackupRequest)
    async throws
  {
    await context.reportBackupFailure(error, job: Self.name)
  }
}

extension QueueContext {
  /// Logs, alerts and records a backup that did not complete.
  ///
  /// Always a warning, never critical: a missed backup needs looking at, but nothing stops working
  /// because of it, and the previous backup is still in the bucket. Deduplicated on
  /// `backup_failed` like a collection alert, so a failure that repeats while someone is already
  /// looking at it does not alert again within ``AlertDeduplication/window``.
  ///
  /// Every failure is logged and stored in `job_failures`, deduplicated or not, so it shows on the
  /// admin console's **Recent failures** card even for a deployment with no Slack webhook.
  ///
  /// Never throws, for the reason `FailureNotifier` gives: the worker clears the job only after
  /// this returns.
  func reportBackupFailure(_ error: any Error, job: String) async {
    let backupError = error as? BackupError
    let identifier = backupError?.identifier ?? "backup_failed"
    let subject = application.databaseBackup?.target.database ?? "database"

    // Only `BackupError` renders its own details: its cases were built to be safe to show.
    // Anything else is named by type alone, since its description was never checked for what it
    // might carry.
    let details =
      backupError?.debuggableHelp(format: .long)
      ?? "The backup failed with an unexpected \(String(describing: type(of: error)))."

    logger.error(
      "Database backup failed.",
      metadata: [
        "job": .string(job),
        "subject": .string(subject),
        "identifier": .string(identifier),
        "reason": .string(backupError?.reason ?? String(describing: type(of: error))),
      ]
    )

    if await claimAlert(identifier: identifier, severity: .warning) {
      let hours = Int(AlertDeduplication.window / 3600)
      await application.notifier.notify(
        FailureAlert(
          severity: .warning,
          job: job,
          subject: subject,
          identifier: identifier,
          details: details
            + "\nThe newest backup in the bucket is from an earlier run. Further '\(identifier)' "
            + "alerts are held back for \(hours) hours.",
        ))
    } else {
      logger.notice(
        "Alert suppressed: an identical one was sent within the deduplication window.",
        metadata: ["job": .string(job), "identifier": .string(identifier)]
      )
    }

    await persistFailure(
      job: job,
      subject: subject,
      identifier: identifier,
      details: details,
      severity: "warning",
    )
  }
}
