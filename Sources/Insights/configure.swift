import Fluent
import FluentPostgresDriver
import Leaf
import NIOSSL
import Queues
import QueuesFluentDriver
import Vapor

/// configures your application
func configure(_ app: Application) async throws {
  // Serve static assets (dashboard CSS/JS) from the /Public folder.
  app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

  // Postgres serves its image's self-signed `CN=localhost` cert, which no CA can vouch
  // for. Encrypt without verifying, matching libpq's `sslmode=require`.
  var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
  tlsConfiguration.certificateVerification = .none

  // Route each context to its own database: tests always hit `test` (so a stray run can
  // never clobber dev/prod), development defaults to `dev`, production reads the env.
  let databaseName =
    switch app.environment {
    case .testing: "test"
    case .development: Environment.get("DATABASE_NAME") ?? "dev"
    default: Environment.get("DATABASE_NAME") ?? "vapor_database"
    }

  try app.databases.use(
    DatabaseConfigurationFactory.postgres(
      configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
          ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: databaseName,
        tls: .require(.init(configuration: tlsConfiguration)),
      )), as: .psql)

  app.migrations.add(JobModelMigration())
  app.migrations.add(FirstMigration())

  // Development-only seed data so the dashboard has something to render. Only ever
  // registered in `.development`, so it targets `dev` and never the `test` database.
  // Real ICICLE figures only: the snapshot is a single point in time, so trend series
  // have one point each until a second sweep is recorded.
  if app.environment == .development {
    app.migrations.add(ICICLESnapshotJuly2026())
  }

  app.views.use(.leaf)
  app.queues.use(.fluent())

    //services
    // Shared Tapis client for resolving Vault secrets in sync jobs. Fail-fast: a missing
    // TAPIS_BASE_URL / TAPIS_TOKEN aborts boot rather than failing on the first Vault call.
    app.tapis = try TapisClient(client: app.client, config: .fromEnvironment())

    // Encode/decode JSON dates as ISO8601 so clients (e.g. the dashboard chart) can parse them.
    let jsonEncoder = JSONEncoder()
    jsonEncoder.dateEncodingStrategy = .iso8601
    let jsonDecoder = JSONDecoder()
    jsonDecoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)
    ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

  // register routes
  try routes(app)
}
