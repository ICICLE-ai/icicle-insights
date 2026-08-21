import Fluent
import FluentSQL
import SQLKit

/// Adds durable operational history for collection jobs that exhaust all retries.
struct JobFailures: AsyncMigration {
  func prepare(on database: any Database) async throws {
    try await database.schema("job_failures")
      .id()
      .field(
        "resource_id", .uuid,
        .references("resources", "id", onDelete: .setNull)
      )
      .field(
        "account_id", .uuid,
        .references("accounts", "id", onDelete: .setNull)
      )
      .field("job", .string, .required)
      .field("subject", .string, .required)
      .field("identifier", .string, .required)
      .field("details", .string, .required)
      .field("severity", .string, .required)
      .field("failed_at", .datetime, .required)
      .create()

    if let sql = database as? any SQLDatabase {
      try await sql.raw(
        "CREATE INDEX idx_job_failures_failed_at ON job_failures (failed_at DESC)"
      ).run()
    }
  }

  func revert(on database: any Database) async throws {
    if let sql = database as? any SQLDatabase {
      try await sql.raw("DROP INDEX IF EXISTS idx_job_failures_failed_at").run()
    }
    try await database.schema("job_failures").delete()
  }
}
