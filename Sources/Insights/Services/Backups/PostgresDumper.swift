import Foundation
import Logging

/// The database a backup dumps.
///
/// Built in `configure` from the very values the connection pool is built from, including the
/// database-name rules, so a backup cannot quietly dump a different database than the one the
/// application writes to.
struct PostgresDumpTarget: Sendable {
  let host: String
  let port: Int
  let username: String
  let password: Secret
  let database: String
  /// False only for `DATABASE_TLS=disable`, as for the pool.
  let requireTLS: Bool

  /// `pg_dump`'s arguments, writing a custom-format archive to `file`.
  ///
  /// Custom format because it is compressed already and `pg_restore` can restore it selectively
  /// or in parallel. Plain SQL was rejected: bigger, and restorable only whole, through `psql`.
  ///
  /// `--no-password` makes a missing or wrong password fail at once instead of waiting for a
  /// prompt nobody can answer. `--lock-wait-timeout` fails the dump if a migration holds a table
  /// lock for more than a minute, rather than queueing behind it for as long as it takes; the
  /// retry a minute or two later then finds the table free.
  ///
  /// The password is not here and must never be: see ``environment(path:)``.
  func arguments(file: String) -> [String] {
    [
      "--format=custom",
      "--no-password",
      "--lock-wait-timeout=60s",
      "--host=\(host)",
      "--port=\(port)",
      "--username=\(username)",
      "--dbname=\(database)",
      "--file=\(file)",
    ]
  }

  /// `pg_dump`'s entire environment.
  ///
  /// The password travels in `PGPASSWORD` because a process's arguments are visible to anything
  /// on the host that can list processes, and its environment is not.
  ///
  /// Built from nothing rather than copied from this process. The child needs no Tapis token,
  /// Slack webhook or bucket secret, so it is not handed any. `PATH` is the one thing inherited,
  /// so `pg_dump` resolves the same way it would in a shell in the same container.
  ///
  /// `PGSSLMODE=require` mirrors the pool's TLS: encrypted, certificate unverified, because the
  /// server's image serves a self-signed `CN=localhost` certificate. libpq upgrades `require` to
  /// verification only if `~/.postgresql/root.crt` exists, which the image never creates.
  func environment(path: String?) -> [String: String] {
    var environment = [
      "PGPASSWORD": password.getSecretValue(),
      "PGSSLMODE": requireTLS ? "require" : "disable",
      // libpq otherwise waits on an unreachable host for as long as the kernel's TCP timeout.
      "PGCONNECT_TIMEOUT": "10",
      // Names the session in `pg_stat_activity`, so a long-running dump is recognisable.
      "PGAPPNAME": "insights-backup",
    ]
    if let path {
      environment["PATH"] = path
    }
    return environment
  }
}

/// Produces a dump of ``PostgresDumpTarget`` with `pg_dump`.
///
/// `pg_dump` rather than a dump over the pool's own connection: it is the only tool that writes
/// an archive `pg_restore` understands, and it takes a consistent snapshot of every table in one
/// transaction. Its major version must be at least the server's, which is why the image installs
/// `postgresql-client-18` from PostgreSQL's own repository; see the Dockerfile.
struct PostgresDumper: Sendable {
  /// Far longer than a dump of this database takes, which is under a second at 120 KB, and still
  /// short enough that a stalled dump frees its worker long before the next day's run.
  static let timeout: Duration = .seconds(600)

  let target: PostgresDumpTarget
  let runner: any ProcessRunner

  /// Dumps the database and returns the archive.
  ///
  /// The archive passes through a temporary file created mode 0600, so other users in the
  /// container cannot read the data while it is being written. The file is removed before this
  /// returns, whatever happened.
  ///
  /// - Throws: ``BackupError`` when `pg_dump` fails, times out or writes nothing.
  func dump(logger: Logger) async throws -> Data {
    let files = FileManager.default
    let file = files.temporaryDirectory
      .appendingPathComponent("insights-backup-\(UUID().uuidString).dump")
    guard
      files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw BackupError.dumpUnreadable("could not create \(file.path)")
    }
    defer { try? files.removeItem(at: file) }

    let outcome: ProcessOutcome
    do {
      outcome = try await runner.run(
        "pg_dump",
        arguments: target.arguments(file: file.path),
        environment: target.environment(path: ProcessInfo.processInfo.environment["PATH"]),
        timeout: Self.timeout,
      )
    } catch {
      throw BackupError.dumpNotStarted(String(reflecting: error))
    }

    guard !outcome.timedOut else {
      throw BackupError.dumpTimedOut(seconds: Int(Self.timeout.components.seconds))
    }

    guard outcome.exitCode == 0 else {
      // pg_dump's own words are the only useful diagnosis, so they go to the worker's log. They
      // stay out of the error, and so out of Slack and `job_failures`: they can quote host,
      // user and server messages, and the alert channel is read by more people than the log.
      // The password cannot appear, since it never reaches pg_dump's arguments, but it is
      // scrubbed anyway in case a future libpq ever echoes it.
      logger.error(
        "pg_dump failed.",
        metadata: [
          "exit_code": .stringConvertible(outcome.exitCode),
          "stderr": .string(scrubbed(outcome.standardError)),
        ]
      )
      throw BackupError.dumpFailed(exitCode: outcome.exitCode)
    }

    let archive: Data
    do {
      archive = try Data(contentsOf: file)
    } catch {
      throw BackupError.dumpUnreadable(String(reflecting: error))
    }
    guard !archive.isEmpty else { throw BackupError.emptyDump }
    return archive
  }

  /// `text` with the password removed and trimmed to a length a log line can carry.
  private func scrubbed(_ text: String) -> String {
    let password = target.password.getSecretValue()
    let clean =
      password.isEmpty ? text : text.replacingOccurrences(of: password, with: "«redacted»")
    return String(clean.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
  }
}
