import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Queues
import Testing
import Vapor
import VaporTesting
import XCTQueues

@testable import Insights

/// Standard test harness: boots a `.testing` app (which connects to the `test` database),
/// migrates, runs the test, then reverts and shuts down.
///
/// `setUp` runs between `configure` and the migration, which is where a test swaps in a
/// different queues driver: the provider also initialises the storage later dispatches read
/// from, so it has to be in place before anything enqueues.
func withApp(
  setUp: (Application) async throws -> Void = { _ in },
  _ test: (Application) async throws -> Void,
) async throws {
  let app = try await Application.make(.testing)
  do {
    try await configure(app)
    try await setUp(app)
    try await app.autoMigrate()
    try await test(app)
    try await app.autoRevert()
  } catch {
    try? await app.autoRevert()
    try await app.asyncShutdown()
    throw error
  }
  try await app.asyncShutdown()
}

/// `withApp` with the in-memory queues driver in place of Fluent's, so dispatches are
/// inspectable through `app.queues.asyncTest` and never touch the jobs table.
func withQueueApp(_ test: (Application) async throws -> Void) async throws {
  try await withApp(setUp: { $0.queues.use(.asyncTest) }, test)
}

/// The context the worker hands a scheduled job, built by hand so a sweep can be run directly
/// rather than through a live scheduler.
func queueContext(for app: Application) -> QueueContext {
  QueueContext(
    queueName: .metrics,
    configuration: app.queues.configuration,
    application: app,
    logger: app.logger,
    on: app.eventLoopGroup.any(),
  )
}

// MARK: - Tapis stub

/// Answers every request with a fixed status and an empty body, so tests can drive the
/// `TapisClientError` paths without touching the network.
struct StubClient: Client {
  let eventLoop: any EventLoop
  let status: HTTPResponseStatus

  func delegating(to eventLoop: any EventLoop) -> any Client {
    StubClient(eventLoop: eventLoop, status: status)
  }

  func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
    eventLoop.makeSucceededFuture(ClientResponse(status: status, headers: [:], body: nil))
  }
}

/// Returns the Tapis adapter configuration installed by `configure`.
private func tapisConfig(on app: Application) -> TapisConfig {
  guard let provider = app.secrets as? TapisClient.Vaults else {
    fatalError("Tests expected configure.swift to install the Tapis secret provider")
  }
  return provider.config
}

/// Repoint `app.secrets` at an always-failing Tapis adapter, reusing its configuration.
func stubTapis(on app: Application, status: HTTPResponseStatus) {
  app.secrets =
    TapisClient(
      client: StubClient(eventLoop: app.eventLoopGroup.any(), status: status),
      config: tapisConfig(on: app),
    ).vaults
}

// MARK: - Platform API stub

/// A `Client` that answers from `respond` and records what it was asked for, so a test can
/// assert on the URL a job built without going near the network.
struct StubHTTPClient: Client {
  let eventLoop: any EventLoop
  /// Shared with every `delegating(to:)` copy, so recordings survive the event-loop hop.
  let requests: NIOLockedValueBox<[ClientRequest]>
  let respond: @Sendable (ClientRequest) -> ClientResponse

  func delegating(to eventLoop: any EventLoop) -> any Client {
    StubHTTPClient(eventLoop: eventLoop, requests: requests, respond: respond)
  }

  func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
    requests.withLockedValue { $0.append(request) }
    return eventLoop.makeSucceededFuture(respond(request))
  }
}

/// One canned answer, keyed by the exact request path.
///
/// Exact rather than a substring because the GitHub paths nest: `/repos/o/n` is a prefix of
/// `/repos/o/n/traffic/clones`, so anything looser lets the repo route answer traffic calls.
/// The query string is excluded, which is what lets the Hub's `expand[]` parameters vary
/// freely while still being recorded for assertions.
struct StubRoute: Sendable {
  let path: String
  let status: HTTPResponseStatus
  let body: String

  static func ok(_ path: String, _ body: String) -> StubRoute {
    .init(path: path, status: .ok, body: body)
  }

  static func failing(_ path: String, _ status: HTTPResponseStatus) -> StubRoute {
    .init(path: path, status: status, body: "")
  }

  static func malformed(_ path: String) -> StubRoute {
    .init(path: path, status: .ok, body: #"{"unexpected": true}"#)
  }
}

private func jsonResponse(_ status: HTTPResponseStatus, _ body: String) -> ClientResponse {
  ClientResponse(
    status: status,
    headers: ["Content-Type": "application/json"],
    body: ByteBuffer(string: body),
  )
}

/// Stub every outbound HTTP call the sync jobs make, returning the recording of what they asked
/// for.
///
/// Both `app.client` and `app.secrets` are replaced: `configure` builds the Tapis adapter from
/// `app.client` at boot, so swapping the client factory alone leaves it holding the real one.
///
/// Vault reads are answered automatically from the secret name in the URL, since that is the
/// key `readSecret` looks the value up under — tests only describe the platform call they care
/// about. Anything unmatched answers 404, which surfaces a job requesting a URL the test did
/// not anticipate rather than silently succeeding.
@discardableResult
func stubAPI(
  on app: Application,
  _ routes: [StubRoute],
  token: String = "platform-token",
) -> NIOLockedValueBox<[ClientRequest]> {
  let requests = NIOLockedValueBox<[ClientRequest]>([])
  let stub = StubHTTPClient(eventLoop: app.eventLoopGroup.any(), requests: requests) { request in
    let path = request.url.path

    if path.contains("/security/vault/secret/user/"),
      let name = path.split(separator: "/").last
    {
      return jsonResponse(.ok, #"{"result":{"secretMap":{"\#(name)":"\#(token)"}}}"#)
    }

    guard let route = routes.first(where: { $0.path == path }) else {
      return ClientResponse(status: .notFound)
    }

    return jsonResponse(route.status, route.body)
  }

  app.clients.use { _ in stub }
  app.secrets = TapisClient(client: stub, config: tapisConfig(on: app)).vaults
  return requests
}

// MARK: - Alert channel stub

/// Captures alerts instead of sending them, so a test can assert on what an operator would have
/// been told without a webhook.
///
/// A struct sharing a box, matching `StubHTTPClient`: `app.notifier` stores an existential the
/// application copies freely, and recordings have to survive that.
struct RecordingNotifier: FailureNotifier {
  let alerts = NIOLockedValueBox<[FailureAlert]>([])

  func notify(_ alert: FailureAlert) async {
    alerts.withLockedValue { $0.append(alert) }
  }

  var recorded: [FailureAlert] {
    alerts.withLockedValue { $0 }
  }
}

/// Installs a recording notifier and hands it back for assertions.
func stubNotifier(on app: Application) -> RecordingNotifier {
  let notifier = RecordingNotifier()
  app.notifier = notifier
  return notifier
}

// MARK: - Failing queue

/// A driver whose first `set` throws, so `CollectDueResources`' per-resource error path can be
/// reached at all — `AsyncTestQueue` never fails, and that branch is what stops one unusable
/// resource from stranding every other one in the sweep.
struct FlakyQueuesDriver: QueuesDriver {
  struct DispatchFailure: Error {}

  let stored = NIOLockedValueBox<[JobIdentifier: JobData]>([:])
  let failuresLeft = NIOLockedValueBox<Int>(1)

  func makeQueue(with context: QueueContext) -> any Queue {
    FlakyQueue(context: context, stored: stored, failuresLeft: failuresLeft)
  }

  func shutdown() {}
}

struct FlakyQueue: AsyncQueue {
  let context: QueueContext
  let stored: NIOLockedValueBox<[JobIdentifier: JobData]>
  let failuresLeft: NIOLockedValueBox<Int>

  func get(_ id: JobIdentifier) async throws -> JobData {
    guard let data = stored.withLockedValue({ $0[id] }) else {
      throw FlakyQueuesDriver.DispatchFailure()
    }
    return data
  }

  func set(_ id: JobIdentifier, to data: JobData) async throws {
    let shouldFail = failuresLeft.withLockedValue { remaining -> Bool in
      guard remaining > 0 else { return false }
      remaining -= 1
      return true
    }

    guard !shouldFail else { throw FlakyQueuesDriver.DispatchFailure() }
    stored.withLockedValue { $0[id] = data }
  }

  func clear(_ id: JobIdentifier) async throws {
    stored.withLockedValue { $0[id] = nil }
  }

  func pop() async throws -> JobIdentifier? { nil }
  func push(_ id: JobIdentifier) async throws {}
}

// MARK: - Fixtures

/// An expiration a year out. The vault endpoints reject dates in the past, so payloads must not
/// hard-code a year that will eventually go stale.
func futureExpires() -> Vault.Expires {
  let calendar = Calendar(identifier: .gregorian)
  let date = calendar.date(byAdding: .year, value: 1, to: Date()) ?? Date()
  let components = calendar.dateComponents([.year, .month, .day], from: date)
  return Vault.Expires(
    day: components.day ?? 1, month: components.month ?? 1, year: components.year ?? 2100)
}

@discardableResult
func makeAccount(
  on db: any Database,
  name: String = "octocat",
  platform: Platform = .github,
  followers: Int = 0,
) async throws -> Account {
  let account = Account(name: name, platform: platform, followers: followers)
  try await account.create(on: db)
  return account
}

@discardableResult
func makeResource(
  on db: any Database,
  accountID: Account.IDValue,
  name: String = "insights",
  type: ResourceType = .model,
  nextCollectionAt: Date? = nil,
  collectionIntervalDays: Int = Resource.defaultCollectionIntervalDays,
) async throws -> Resource {
  let resource = Resource(
    name: name,
    type: type,
    accountID: accountID,
    nextCollectionAt: nextCollectionAt,
    collectionIntervalDays: collectionIntervalDays,
  )
  try await resource.create(on: db)
  return resource
}

@discardableResult
func makeMetric(
  on db: any Database,
  resourceID: Resource.IDValue,
  reading: Double = 1,
  type: MetricType = .stars,
) async throws -> Metric {
  let metric = Metric(resourceID: resourceID, reading: reading, type: type)
  try await metric.create(on: db)
  return metric
}

@discardableResult
func makeRelease(
  on db: any Database,
  resourceID: Resource.IDValue,
  version: String = "1.0.0",
) async throws -> Release {
  let release = Release(resourceID: resourceID, version: version)
  try await release.create(on: db)
  return release
}

@discardableResult
func makeVault(
  on db: any Database,
  accountID: Account.IDValue,
  name: String = "github-token",
) async throws -> Vault {
  let vault = Vault(accountID: accountID, name: name)
  try await vault.create(on: db)
  return vault
}
