import Logging
import Vapor

/// Why a database backup did not reach the bucket.
///
/// Every associated value is safe to show in an alert. None carries `pg_dump`'s standard error,
/// a request header, or anything derived from a password or secret key: that is the reason each
/// failure is reduced to one of these cases before it leaves the backup code.
enum BackupError: Error {
  /// A backup job reached a worker whose own environment has no `BACKUP_S3_BUCKET`.
  case notConfigured
  /// `pg_dump` could not be launched at all.
  case dumpNotStarted(String)
  /// `pg_dump` exited with a failure status. Its message is in the worker's log.
  case dumpFailed(exitCode: Int32)
  /// `pg_dump` was stopped for running too long.
  case dumpTimedOut(seconds: Int)
  /// `pg_dump` succeeded but its archive could not be read back.
  case dumpUnreadable(String)
  /// `pg_dump` succeeded and wrote nothing.
  case emptyDump
  /// The store answered the upload with something other than 200.
  case uploadRejected(status: UInt, code: String?, message: String?)
  /// The store could not be reached, or did not answer.
  case uploadUnreachable(String)
}

/// `DebuggableError` so `Logger.report(error:)` and the alert both read `reason` and the fixes,
/// as they do for `JobError`.
extension BackupError: DebuggableError {
  /// One identifier for every case, and the one the alert is deduplicated on.
  ///
  /// The cases differ in what to fix, which the reason and fixes already say. They do not differ
  /// in what someone has to know, which is that last night's backup is missing. Separate
  /// identifiers would also let a dump failure and an upload failure on consecutive retries each
  /// send their own alert for the same missed backup.
  var identifier: String {
    "backup_failed"
  }

  var reason: String {
    switch self {
    case .notConfigured:
      "A backup was queued, but this worker has no BACKUP_S3_BUCKET, so it cannot upload one"
    case .dumpNotStarted(let detail):
      "pg_dump could not be started: \(detail)"
    case .dumpFailed(let exitCode) where exitCode == 127:
      "pg_dump was not found on this worker's PATH (exit status 127)"
    case .dumpFailed(let exitCode):
      "pg_dump exited with status \(exitCode). Its own message is in the worker's log"
    case .dumpTimedOut(let seconds):
      "pg_dump was stopped after running for \(seconds / 60) minutes"
    case .dumpUnreadable(let detail):
      "pg_dump finished, but its archive could not be read: \(detail)"
    case .emptyDump:
      "pg_dump finished but wrote an empty archive"
    case .uploadRejected(let status, let code, let message):
      "The bucket refused the upload with status \(status)"
        + (code.map { " \($0)" } ?? "")
        + (message.map { ": \($0)" } ?? "")
    case .uploadUnreachable(let detail):
      "The bucket could not be reached: \(detail)"
    }
  }

  /// Written as instructions to whoever reads the alert, like `JobError`'s.
  var suggestedFixes: [String] {
    switch self {
    case .notConfigured:
      ["Set the BACKUP_S3_* variables on the queue worker as well as the scheduler, and restart."]
    case .dumpNotStarted, .dumpFailed(exitCode: 127):
      ["Check the worker runs the current image, which installs postgresql-client-18."]
    case .dumpFailed:
      [
        "Read the `pg_dump failed.` line in the worker's log for the cause.",
        "Run `./Insights backup-database` in the worker's container to retry and see it directly.",
      ]
    case .dumpTimedOut:
      ["Check the database is reachable from the worker and not blocked by a long-held lock."]
    case .dumpUnreadable, .emptyDump:
      ["Check the worker's temporary directory is writable and not full."]
    case .uploadRejected(let status, _, _) where status == 401 || status == 403:
      [
        "Check BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY, and that the key may "
          + "PutObject under BACKUP_S3_PREFIX.",
        "A SignatureDoesNotMatch usually means a wrong secret or BACKUP_S3_REGION.",
      ]
    case .uploadRejected:
      // A wrong region is a 400 AuthorizationHeaderMalformed, not a 403, so it is named here too.
      [
        "Check BACKUP_S3_BUCKET, BACKUP_S3_REGION and BACKUP_S3_PATH_STYLE.",
        "If the store refuses encryption headers, set BACKUP_S3_SSE=false.",
      ]
    case .uploadUnreachable:
      ["Check BACKUP_S3_ENDPOINT and that the worker can reach it."]
    }
  }

  /// `.error` for all: a missed backup deserves a look, but nothing stops working because of
  /// it, so it is not raised to `.critical` alongside dead credentials.
  var logLevel: Logger.Level {
    .error
  }
}
