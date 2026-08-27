import Fluent
import FluentPostgresDriver
import JWT
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
  // Where `serve` binds, read from the environment rather than passed as `--hostname`/`--port`.
  // Same reasoning as VAPOR_ENV: a flag on the command line outranks the variable, so pinning it
  // on one process is how a stack ends up disagreeing with itself. Setting the configuration here
  // means `serve` needs no flags at all, and every process reads its address the same way.
  //
  // 0.0.0.0 rather than Vapor's own default of 127.0.0.1, which listens only on the loopback
  // interface and leaves a container unreachable from outside itself. A hostname resolves to an
  // address that must already be on a local interface — a public domain belongs at the ingress,
  // not here; this value only chooses which interfaces to accept connections on.
  app.http.server.configuration.hostname = Environment.get("SERVER_HOSTNAME") ?? "0.0.0.0"
  app.http.server.configuration.port =
    Environment.get("SERVER_PORT").flatMap(Int.init(_:)) ?? 8080

  // All three stamp *response* headers, which are applied on the way back out — so they must sit
  // ahead of `ErrorMiddleware`, or an error response leaves without them. A 4xx with no CORS
  // headers is unreadable to the browser that caused it, which is exactly when reading it
  // matters, and a 500 is the response whose ID someone most wants to quote. `.beginning` puts
  // them in front of Vapor's defaults.
  let corsOrigins = corsOriginsFromEnvironment()
  if let cors = corsMiddleware(origins: corsOrigins) {
    app.middleware.use(cors, at: .beginning)
  }

  let frameAncestors = SecurityHeadersMiddleware.frameAncestorsFromEnvironment(logger: app.logger)
  app.middleware.use(
    SecurityHeadersMiddleware(
      includeHSTS: app.environment == .production,
      frameAncestors: frameAncestors,
    ), at: .beginning)

  app.middleware.use(RequestIDMiddleware(), at: .beginning)

  // The bind address is logged with the rest of the HTTP surface because getting it wrong is
  // silent from the inside: the process starts and answers on loopback while every request from
  // outside the container is refused with nothing written to explain it.
  app.logger.notice(
    "HTTP middleware configured.",
    metadata: [
      "bind": .string(
        "\(app.http.server.configuration.hostname):\(app.http.server.configuration.port)"),
      "cors_origins": .string(
        corsOrigins.isEmpty ? "disabled" : corsOrigins.joined(separator: ",")),
      "frame_ancestors": .string(
        frameAncestors.isEmpty ? "denied" : frameAncestors.joined(separator: ",")),
      "hsts": .stringConvertible(app.environment == .production),
    ]
  )

  // Both policies sit outside FileMiddleware in the chain so they can classify the response it
  // returns. Hashed Angular assets are immutable; index.html and SPA deep links revalidate.
  app.middleware.use(StaticAssetCacheMiddleware(), at: .beginning)

  // Serve the Angular artifacts produced into /Public by the Docker frontend stage.
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

  // Bound to a name rather than built inline because two things need it: the pool below, and the
  // single connection `migrate-locked` dials for its advisory lock. Sharing the value is what stops
  // the lock connection drifting from the database everything else talks to.
  let postgresConfiguration = try SQLPostgresConfiguration(
    hostname: Environment.get("DATABASE_HOST") ?? "localhost",
    port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
      ?? SQLPostgresConfiguration.ianaPortNumber,
    username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
    password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
    database: databaseName,
    tls: Environment.get("DATABASE_TLS") == "disable"
      ? .disable
      : .require(.init(configuration: tlsConfiguration)),
  )

  app.databases.use(
    DatabaseConfigurationFactory.postgres(configuration: postgresConfiguration), as: .psql)
  app.migrationLockConfiguration = postgresConfiguration

  app.migrations.add(FirstMigration())
  app.migrations.add(RecurringCollection())
  app.migrations.add(ServiceTokens())
  app.migrations.add(Admins())
  app.migrations.add(JobFailures())
  app.migrations.add(CollectionBackoff())
  app.migrations.add(PatraPlatform())

  // Development-only seed data so the dashboard has something to render. Only ever
  // registered in `.development`, so it targets `dev` and never the `test` database.
  // Real ICICLE figures only: the snapshot is a single point in time, so trend series
  // have one point each until a second sweep is recorded.
  if app.environment == .development {
    app.migrations.add(ICICLESnapshotJuly2026())
  }

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

  // Loaded before the provider switch because two unrelated things need it: the Vault client
  // below, and TapisAuthenticator, which checks a caller's tenant claim against this one.
  app.tapisConfig = try .fromEnvironment()

  // Credential backend selected once for the entire application. Jobs and controllers depend
  // only on SecretProvider, so another implementation adds one case here, not changes to every
  // consumer. Tapis Vault is the current adapter and fails fast on missing Tapis configuration.
  let secretProviderName = Environment.get("SECRET_PROVIDER")?.lowercased() ?? "tapis"
  switch secretProviderName {
  case "tapis":
    app.secrets = TapisClient(client: app.client, config: app.tapisConfig).vaults
  default:
    throw ConfigError.unsupported(name: "SECRET_PROVIDER", value: secretProviderName)
  }

  // The tenant and base URL are logged because getting either wrong is silent and expensive: a
  // mismatched tenant refuses every admin with a plain 403, and a base URL missing its `/v3`
  // fails the tenant key fetch below with an error that names the URL but not the setting.
  app.logger.notice(
    "Secret provider selected.",
    metadata: [
      "provider": .string(secretProviderName),
      "tapis_base_url": .string(app.tapisConfig.baseURL),
      "tapis_tenant": .string(app.tapisConfig.tenant),
    ]
  )

  // Rate limit counters share the Valkey instance queues already use, so limits hold across
  // pods rather than being granted afresh by each replica.
  app.redis.configuration = try RedisConfiguration(
    hostname: Environment.get("REDIS_HOST") ?? "localhost",
    port: Environment.get("REDIS_PORT").flatMap(Int.init(_:)) ?? 6379,
    password: Environment.get("REDIS_PASSWORD").flatMap { $0.isEmpty ? nil : $0 },
  )

  // The break-glass admin. Everyone else is managed from the dashboard, but this one holds
  // access whatever the table says, so an accidental deletion can always be undone. Parsed here
  // so a missing value fails the boot rather than every write returning 403 in production.
  app.rootAdmin = try Application.rootAdminFromEnvironment()
  app.logger.notice(
    "Root admin resolved.", metadata: ["username": .string(app.rootAdmin)])

  // Both of these reach the network, so tests skip them and inject their own fixtures through
  // `withApp(setUp:)` instead — a throwaway keypair for the tenant key, and a registry built
  // in memory. Without them the authenticators simply recognize nobody.
  if app.environment != .testing {
    // Fetched rather than pinned in source: a Tapis key rotation becomes a restart instead of
    // every request failing 401 with nothing in the log to explain it.
    //
    // One key, registered as the default signer. Tokens carry a `kid`, but Tapis publishes no
    // key set to resolve it against — its `jwks_uri` points back at the tenant record — so
    // there is nothing to route between. See `TapisClient+Auth.swift`.
    let tapis = TapisClient(client: app.client, config: app.tapisConfig)
    try await app.jwt.keys.add(
      rsa: Insecure.RSA.PublicKey(pem: try await tapis.getTenantPublicKey()),
      digestAlgorithm: .sha256)
    app.logger.notice("Tapis tenant public key loaded; admin tokens verify locally.")

    // Held apart from `app.jwt.keys` on purpose — see `Application+SigningKey.swift`. Missing
    // means `service-token init-key` has not been run; webhook tokens cannot be minted or
    // verified until it has.
    if let registered = try await app.loadServiceTokenKeys(from: app.secrets) {
      app.logger.notice(
        "Webhook token signing keys loaded.",
        metadata: [
          "keys": .stringConvertible(registered),
          "active_kid": .string(app.activeSigningKid),
        ]
      )
    } else {
      // Not a fault — a deployment that has not been bootstrapped yet. Said loudly and with the
      // exact command, because the underlying error is a bare 404 that names neither the secret
      // nor the fix, and because every webhook silently stops working until it is resolved.
      app.logger.critical(
        """
        No webhook token signing keyset found. Run `swift run Insights service-token init-key` \
        once, then restart. Until then webhook tokens cannot be minted or verified; \
        admin access, public reads, and collection are unaffected.
        """,
        metadata: ["secret": .string(ServiceTokenSigningKey.secretName)]
      )
    }
  } else {
    app.logger.notice("Testing environment: skipping Tapis key fetch and Vault keyset read.")
  }

  // Where collection failures that need a human are announced. Optional by design: with no
  // webhook configured this resolves to `NoopNotifier` and failures stay in the log, which is
  // what every test run and local `swift run` wants.
  app.notifier = SlackNotifier.fromEnvironment(client: app.client, logger: app.logger)
  app.logger.notice(
    "Failure alerting configured.",
    metadata: ["channel": .string(app.notifier is SlackNotifier ? "slack" : "log only")]
  )

  // Encode/decode JSON dates as ISO8601 so clients (e.g. the dashboard chart) can parse them.
  let jsonEncoder = JSONEncoder()
  jsonEncoder.dateEncodingStrategy = .iso8601
  let jsonDecoder = JSONDecoder()
  jsonDecoder.dateDecodingStrategy = .iso8601
  ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)
  ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

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

  // Daily, and the cadence is what makes the thresholds work: each fires once as a token's
  // remaining days pass through it. Early morning, so a warning is waiting at the start of a
  // working day rather than arriving in the middle of one.
  app.queues.schedule(WarnExpiringServiceTokens()).daily().at(7, 0)

  // One-shot equivalents for local testing and operator-initiated backfills. They invoke the
  // same scheduled job types without changing or waiting for the production clocks above.
  app.asyncCommands.use(CollectResourcesNowCommand(), as: "collect-resources")
  app.asyncCommands.use(CollectAccountsNowCommand(), as: "collect-accounts")

  // Credential minting stays off the HTTP surface — see `ServiceTokenCommand`.
  app.asyncCommands.use(ServiceTokenCommand(), as: "service-token")

  // What the container entrypoint runs before `serve`. Vapor's own `migrate` stays available and
  // remains the right command for a deliberate deployment step; this one is safe to run from
  // several replicas at once.
  app.asyncCommands.use(MigrateLockedCommand(), as: "migrate-locked")

  app.logger.notice(
    "Insights configured.",
    metadata: [
      "environment": .string(app.environment.name),
      "database": .string(databaseName),
    ]
  )
}

/// Reads the browser origins permitted to call this API from `CORS_ORIGINS`.
private func corsOriginsFromEnvironment() -> [String] {
  guard let raw = Environment.get("CORS_ORIGINS") else { return [] }

  return
    raw.split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}

/// Builds the CORS middleware, or nil when no origins are configured.
///
/// Returning nil rather than a permissive default is the point: a same-origin deployment then
/// carries no CORS surface at all, and enabling it for another ICICLE site is a config change
/// rather than a code change.
private func corsMiddleware(origins: [String]) -> CORSMiddleware? {
  guard !origins.isEmpty else { return nil }

  return CORSMiddleware(
    configuration: .init(
      allowedOrigin: .any(origins),
      allowedMethods: [.GET, .POST, .PATCH, .DELETE, .OPTIONS],
      // `.authorization` is not optional here: without it a browser refuses to send the Tapis
      // token, and every cross-origin call from the dashboard arrives anonymous.
      allowedHeaders: [
        .accept,
        .authorization,
        .contentType,
        .origin,
        .init("X-Request-ID"),
        .init("X-Tapis-Token"),
      ],
    ))
}
