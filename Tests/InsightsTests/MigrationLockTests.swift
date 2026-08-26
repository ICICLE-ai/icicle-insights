import Fluent
import NIOPosix
import Testing
import Vapor

@testable import Insights

/// Regression coverage for `migrate-locked`.
@Suite("Migration lock")
struct MigrationLockTests {
  /// Migrating under the advisory lock must finish when the process has exactly one event loop.
  ///
  /// This pins the group to a single thread on purpose, and that is the whole point of the test.
  /// Fluent's `maxConnectionsPerEventLoop` defaults to 1, so one event loop means the pool holds
  /// exactly one connection — the shape of a container limited to a single CPU. Taking the lock on
  /// a pooled connection and then calling `autoMigrate()` deadlocks there, because `autoMigrate`
  /// asks the same pool for the connection the lock is already holding and waits until
  /// `connectionRequestTimeout` fires.
  ///
  /// A default multi-threaded group hides the bug: `autoMigrate` usually lands on a different event
  /// loop with a spare connection, which is why this reached production. The single thread is what
  /// makes this test capable of failing.
  @Test("applies migrations on a single-event-loop process")
  func migratesOnASingleEventLoop() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let app = try await Application.make(.testing, .shared(group))

    do {
      try await configure(app)
      try await app.asyncBoot()
      try await app.migrateUnderAdvisoryLock()

      // Proves the migrations actually ran rather than the call merely returning: `admins` only
      // exists once the schema is applied.
      _ = try await Admin.query(on: app.db).count()

      try await app.autoRevert()
    } catch {
      try? await app.autoRevert()
      try? await app.asyncShutdown()
      try await group.shutdownGracefully()
      throw error
    }

    try await app.asyncShutdown()
    try await group.shutdownGracefully()
  }
}
