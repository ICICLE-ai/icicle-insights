import Vapor

/// Takes a backup now, inline, and waits for it to finish.
///
/// The on-demand counterpart of the 02:00 schedule, and the way to check a new configuration:
/// it exercises the same dump and upload, but prints the result to the terminal instead of
/// queueing a job for a worker. Unlike the collect commands it needs no worker running.
///
/// It sends no Slack alert. Whoever runs it is watching the terminal, where a failure is printed,
/// together with `pg_dump`'s own message when that is the step that failed.
struct BackupDatabaseCommand: AsyncCommand {
  /// This command intentionally accepts no options.
  struct Signature: CommandSignature {}

  /// A concise description displayed by Vapor's command-line help.
  var help: String {
    "Back up the database to object storage now, and wait for the upload."
  }

  /// Dumps and uploads once.
  ///
  /// - Parameters:
  ///   - context: Vapor's command context containing the configured application.
  ///   - signature: The command's empty parsed signature.
  /// - Throws: ``ConfigError`` when backups are disabled, or ``BackupError`` when one fails.
  ///   Either way the command exits non-zero, which is what makes it usable as a check.
  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application

    guard let backup = application.databaseBackup else {
      throw ConfigError.missing("BACKUP_S3_BUCKET (backups are disabled)")
    }

    context.console.info(
      "Backing up '\(backup.target.database)' to bucket '\(backup.storage.bucket)'…")
    let receipt = try await backup.run(client: application.client, logger: application.logger)
    context.console.info("Uploaded \(receipt.bytes) bytes to \(receipt.key).")
  }
}
