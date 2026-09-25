import Queues
import Vapor

import struct Foundation.Date

/// Daily trigger for a database backup.
///
/// Only enqueues, like the collection sweeps: `BackupDatabase` runs on the `metrics` worker,
/// where it has retries and cannot delay the scheduler's other jobs.
///
/// Registered whatever the configuration, and does nothing when this process has no bucket. That
/// keeps "are backups on?" answered in one place, `BACKUP_S3_BUCKET`, rather than by whether a
/// schedule happened to be registered.
struct ScheduleDatabaseBackup: AsyncScheduledJob {
  /// Queues one backup if backups are configured.
  func run(context: QueueContext) async throws {
    await context.recordSchedulerHeartbeat(job: "ScheduleDatabaseBackup")

    // Silent when disabled: every process already said so once at boot.
    guard context.application.databaseBackup != nil else { return }

    try await context.queues(.metrics).dispatch(
      BackupDatabase.self,
      DatabaseBackupRequest(requestedAt: Date()),
      maxRetryCount: backupMaxRetryCount,
    )
  }
}
