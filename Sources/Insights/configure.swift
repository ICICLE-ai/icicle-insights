import Fluent
import FluentPostgresDriver
import Leaf
import NIOSSL
import Queues
import QueuesRedisDriver
import Vapor

/// Configures infrastructure, services, routes, queue handlers, and command-line commands.
///
/// This is the application's composition root. It selects the environment-specific database,
/// connects Valkey-backed queues, initializes Tapis Vault access, and registers both scheduled
/// and one-shot collection entry points.
///
/// - Parameter app: The Vapor application being prepared for execution.
/// - Throws: A configuration, migration registration, service, route, or queue setup error.
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
        tls: Environment.get("DATABASE_TLS") == "disable"
          ? .disable
          : .require(.init(configuration: tlsConfiguration)),
      )), as: .psql)

  app.migrations.add(FirstMigration())
  app.migrations.add(RecurringCollection())

  // Development-only seed data so the dashboard has something to render. Only ever
  // registered in `.development`, so it targets `dev` and never the `test` database.
  // Real ICICLE figures only: the snapshot is a single point in time, so trend series
  // have one point each until a second sweep is recorded.
  if app.environment == .development {
    app.migrations.add(ICICLESnapshotJuly2026())
  }

  app.views.use(.leaf)

  // Jobs live in Redis rather than Postgres: the worker's poll is a blocking pop instead of a
  // table scan on every tick. Assembled from parts rather than a `redis://` URL so a generated
  // password never has to survive percent-encoding, and defaulting to a local unauthenticated
  // server so `swift run` needs no extra configuration.
  try app.queues.use(
    .redis(
      RedisConfiguration(
        hostname: Environment.get("REDIS_HOST") ?? "localhost",
        port: Environment.get("REDIS_PORT").flatMap(Int.init(_:)) ?? 6379,
        // An empty value means "no auth"; passing it through would fail the AUTH handshake.
        password: Environment.get("REDIS_PASSWORD").flatMap { $0.isEmpty ? nil : $0 },
      )))

  // Credential backend selected once for the entire application. Jobs and controllers depend
  // only on SecretProvider, so another implementation adds one case here, not changes to every
  // consumer. Tapis Vault is the current adapter and fails fast on missing Tapis configuration.
  let secretProviderName = Environment.get("SECRET_PROVIDER")?.lowercased() ?? "tapis"
  switch secretProviderName {
  case "tapis":
    app.secrets = try TapisClient(client: app.client, config: .fromEnvironment()).vaults
  default:
    throw ConfigError.unsupported(name: "SECRET_PROVIDER", value: secretProviderName)
  }

  // Where collection failures that need a human are announced. Optional by design: with no
  // webhook configured this resolves to `NoopNotifier` and failures stay in the log, which is
  // what every test run and local `swift run` wants.
  app.notifier = SlackNotifier.fromEnvironment(client: app.client, logger: app.logger)

  // Encode/decode JSON dates as ISO8601 so clients (e.g. the dashboard chart) can parse them.
  let jsonEncoder = JSONEncoder()
  jsonEncoder.dateEncodingStrategy = .iso8601
  let jsonDecoder = JSONDecoder()
  jsonDecoder.dateDecodingStrategy = .iso8601
  ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)
  ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

  // register routes
  try routes(app)

  // Queue Jobs
  let syncGitHubRepoStatsJob = SyncGitHubRepoStats()
  let syncGitHubOrgStatsJob = SyncGitHubOrgStats()
  let syncHuggingFaceHubStats = SyncHuggingFaceHubStats()

  app.queues.add(syncGitHubRepoStatsJob)
  app.queues.add(syncGitHubOrgStatsJob)
  app.queues.add(syncHuggingFaceHubStats)

  // Run by the `--scheduled` worker. These only enqueue; the jobs run on the `metrics` queue,
  // so a slow sync never delays the next sweep.
  app.queues.schedule(CollectDueResources()).hourly().at(0)
  app.queues.schedule(CollectAccountStats()).monthly().on(.first).at(3, 0)

  // One-shot equivalents for local testing and operator-initiated backfills. They invoke the
  // same scheduled job types without changing or waiting for the production clocks above.
  app.asyncCommands.use(CollectResourcesNowCommand(), as: "collect-resources")
  app.asyncCommands.use(CollectAccountsNowCommand(), as: "collect-accounts")
}
