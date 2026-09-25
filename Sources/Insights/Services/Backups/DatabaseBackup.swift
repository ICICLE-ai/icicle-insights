import Foundation
import Logging
import Vapor

/// Dumps the application's database and uploads the archive to object storage.
///
/// Runs inside the application, on the existing scheduler and queue, rather than as a separate
/// backup container. A sidecar or CronJob was rejected because Tapis Pods offers no cron we know
/// of, a separate pod is one more thing to deploy and watch, and it would need its own way to
/// alert. Here a failure goes through the same notifier and deduplication as a failed collection.
///
/// Retention is left to the bucket's lifecycle rule rather than done here. Deleting old backups
/// from code needs `DeleteObject` and `ListBucket` permission, and a key allowed to delete is a key
/// that can destroy every backup if it leaks. With a lifecycle rule the key only ever writes.
struct DatabaseBackup: Sendable {
  let target: PostgresDumpTarget
  let storage: BackupStorage
  let runner: any ProcessRunner

  /// What a successful backup produced.
  struct Receipt: Sendable, Equatable {
    let bucket: String
    let key: String
    let bytes: Int
  }

  /// `{prefix}{database}/{yyyy}/{mm}/{database}-{yyyyMMdd'T'HHmmss'Z'}.dump`.
  ///
  /// The year and month folders keep a listing short enough to browse by hand when choosing a
  /// backup to restore, and let a lifecycle rule or a one-off cleanup target a month. The database
  /// name appears twice so a downloaded file still says what it is once it leaves the bucket.
  /// UTC, in the same basic ISO 8601 form SigV4 stamps requests with, so keys sort by time.
  func objectKey(at date: Date) -> String {
    let stamp = SignatureV4.timestamp(date)
    let year = stamp.prefix(4)
    let month = stamp.dropFirst(4).prefix(2)
    let database = target.database
    return "\(storage.prefix)\(database)/\(year)/\(month)/\(database)-\(stamp).dump"
  }

  /// Takes one backup and uploads it, logging the key and size at `notice` on success.
  ///
  /// Safe to repeat, as a job must be: a second run writes a second object under its own
  /// timestamp and replaces nothing. The key is stamped with the moment the dump starts, so it
  /// says how current the data is rather than when the upload finished.
  ///
  /// - Parameters:
  ///   - client: The HTTP client to upload through.
  ///   - logger: Receives the success line, and `pg_dump`'s message if it fails.
  ///   - now: The instant the key is stamped with and the request is signed at.
  /// - Throws: ``BackupError``, for every failure.
  func run(client: any Client, logger: Logger, now: Date = Date()) async throws -> Receipt {
    let key = objectKey(at: now)
    let archive = try await PostgresDumper(target: target, runner: runner).dump(logger: logger)
    try await storage.putObject(key: key, body: archive, client: client, date: now)

    let receipt = Receipt(bucket: storage.bucket, key: key, bytes: archive.count)
    logger.notice(
      "Database backup uploaded.",
      metadata: [
        "bucket": .string(receipt.bucket),
        "key": .string(receipt.key),
        "bytes": .stringConvertible(receipt.bytes),
      ]
    )
    return receipt
  }
}

extension Application {
  private struct DatabaseBackupKey: StorageKey {
    typealias Value = DatabaseBackup
  }

  /// The configured backup, or nil when `BACKUP_S3_BUCKET` is unset and backups are disabled.
  ///
  /// Set once by `configure`. Replaceable so tests can swap in a stubbed process runner.
  var databaseBackup: DatabaseBackup? {
    get { storage[DatabaseBackupKey.self] }
    set { storage[DatabaseBackupKey.self] = newValue }
  }
}
