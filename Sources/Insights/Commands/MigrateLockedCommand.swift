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

extension Application {
  private struct MigrationLockConfigurationKey: StorageKey {
    typealias Value = SQLPostgresConfiguration
  }

  /// The PostgreSQL settings the migration lock dials its own connection with.
  ///
  /// Set by `configure` from the very value the pool is built from, so the lock cannot end up
  /// serializing against a different database than the one being migrated.
  var migrationLockConfiguration: SQLPostgresConfiguration? {
    get { storage[MigrationLockConfigurationKey.self] }
    set { storage[MigrationLockConfigurationKey.self] = newValue }
  }

  /// Applies migrations while holding a PostgreSQL advisory lock, so concurrent container starts
  /// serialize instead of racing.
  ///
  /// The lock is taken on a connection dialled directly, never one checked out of the pool, and
  /// that is the whole point. Holding a pooled connection across `autoMigrate()` deadlocks:
  /// `autoMigrate` asks the same pool for a connection, `maxConnectionsPerEventLoop` defaults to 1,
  /// and a container pinned to a single CPU has one event loop — so the migrator waits on the
  /// connection it is itself holding until `connectionRequestTimeout` fires and the process dies.
  /// That took a production deployment down. It is invisible on a developer machine, where several
  /// event loops mean `autoMigrate` usually finds a spare connection on a different one.
  ///
  /// The lock is session-scoped rather than transaction-scoped because a migration manages its own
  /// transactions — there is no single one to attach to. Session scope also fails safe: PostgreSQL
  /// drops the lock when the connection closes, so closing is the only release this needs, and it
  /// still covers a migrator killed mid-run, where an explicit unlock would never execute. Waiting
  /// is the correct behaviour for the losing replica: it blocks until the winner is done, then
  /// finds every migration applied and does nothing.
  func migrateUnderAdvisoryLock() async throws {
    guard let configuration = migrationLockConfiguration else {
      // Every supported deployment is PostgreSQL. Refusing beats migrating unserialized, which
      // would look identical right up until two replicas raced.
      throw ConfigError.unsupported(name: "DATABASE", value: "advisory locking requires PostgreSQL")
    }

    let connection = try await PostgresConnection.connect(
      on: eventLoopGroup.any(),
      configuration: configuration.coreConfiguration,
      id: 0,
      logger: logger,
    ).get()

    do {
      logger.notice("Waiting for the migration lock.")
      try await connection.sql().raw(
        "SELECT pg_advisory_lock(hashtext(\(bind: migrationLockName)))"
      ).run()

      // Runs on the pool, which is untouched by the lock above and so has every connection it
      // would ordinarily have.
      try await autoMigrate()
    } catch {
      try? await connection.close()
      throw error
    }

    // Releases the advisory lock. The session owned it, so closing is the release.
    try await connection.close()
    logger.notice("Migrations applied.")
  }
}

/// Applies migrations under a PostgreSQL advisory lock, so concurrent container starts serialize
/// instead of racing.
///
/// Vapor's built-in `migrate` is the right command for an operator running one deployment step by
/// hand. It is the wrong one for a container entrypoint: several replicas of `serve` start at once
/// and Fluent takes no lock of its own, so they would race on the DDL and on `_fluent_migrations`.
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
    try await context.application.migrateUnderAdvisoryLock()
  }
}
