import Fluent
import FluentPostgresDriver
import SQLKit
import Vapor

/// Advisory-lock key for the migration critical section.
///
/// `hashtext` rather than Swift's `hashValue`, which is seeded per process and so differs between
/// the very replicas this is meant to serialize. Same reasoning as `Metric.lockAllTime`, and the
/// same reason the key is a literal string: it has to hash identically everywhere.
private let migrationLockName = "insights:migrate"

/// Applies migrations under a PostgreSQL advisory lock, so concurrent container starts serialize
/// instead of racing.
///
/// Vapor's built-in `migrate` is the right command for an operator running one deployment step by
/// hand. It is the wrong one for a container entrypoint: several replicas of `serve` start at once
/// and Fluent takes no lock of its own, so they would race on the DDL and on `_fluent_migrations`.
///
/// The lock is session-scoped rather than transaction-scoped because a migration manages its own
/// transactions — there is no single one to attach to. Session scope also fails safe: PostgreSQL
/// drops the lock when the connection closes, so a migrator killed mid-run releases it rather than
/// wedging every future start. Waiting is the correct behaviour for the losing replica: it blocks
/// until the winner is done, then finds every migration applied and does nothing.
struct MigrateLockedCommand: AsyncCommand {
  /// This command intentionally accepts no options; it never prompts.
  struct Signature: CommandSignature {}

  /// A concise description displayed by Vapor's command-line help.
  var help: String {
    "Apply pending migrations, serialized across replicas by an advisory lock."
  }

  /// Acquires the lock, migrates, and releases it.
  ///
  /// - Parameters:
  ///   - context: Vapor's command context containing the configured application.
  ///   - signature: The command's empty parsed signature.
  /// - Throws: Database errors from acquiring the lock or applying a migration.
  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application

    guard let sql = application.db(.psql) as? any SQLDatabase else {
      // Every supported deployment is PostgreSQL. Refusing beats migrating unserialized, which
      // would look identical right up until two replicas raced.
      throw ConfigError.unsupported(name: "DATABASE", value: "advisory locking requires PostgreSQL")
    }

    // One connection for the whole critical section: a session-level advisory lock belongs to the
    // connection that took it, so acquiring and releasing on different pooled connections would
    // leak the lock until the process exited.
    try await sql.withSession { session in
      application.logger.notice("Waiting for the migration lock.")
      try await session.raw(
        "SELECT pg_advisory_lock(hashtext(\(bind: migrationLockName)))"
      ).run()

      do {
        // The migrations themselves run on the pool, not on this session. The lock excludes other
        // *processes*, which is the whole requirement; it does not need to own the DDL connection.
        try await application.autoMigrate()
      } catch {
        try? await session.raw(
          "SELECT pg_advisory_unlock(hashtext(\(bind: migrationLockName)))"
        ).run()
        throw error
      }

      try await session.raw(
        "SELECT pg_advisory_unlock(hashtext(\(bind: migrationLockName)))"
      ).run()
    }

    application.logger.notice("Migrations applied.")
  }
}
