import Fluent
import Foundation
import JWT
import JWTKit
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
///
/// Deliberately *not* named `withApp`. `VaporTesting` exports a generic `withApp` of its own
/// that boots a bare application without `configure`, and for a single-expression closure the
/// type checker prefers it — silently handing the test an app with no routes and no database,
/// which surfaces as an inexplicable 404. Adding a second statement to the closure changes
/// which overload wins, so the trap is invisible until it bites. A distinct name removes it.
func withInsightsApp(
  setUp: (Application) async throws -> Void = { _ in },
  _ test: (Application) async throws -> Void,
) async throws {
  let app = try await Application.make(.testing)
  do {
    try await configure(app)
    try await installTestCredentials(on: app)
    try await setUp(app)
    // Match the production lifecycle before a test reaches Redis-backed middleware or jobs.
    // Redis creates its event-loop-bound pools during boot; accessing it earlier is a fatal
    // programmer error rather than a throwable connection failure.
    try await app.asyncBoot()
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

/// `withInsightsApp` with the in-memory queues driver in place of Fluent's, so dispatches are
/// inspectable through `app.queues.asyncTest` and never touch the jobs table.
func withQueueApp(_ test: (Application) async throws -> Void) async throws {
  try await withInsightsApp(setUp: { $0.queues.use(.asyncTest) }, test)
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

// MARK: - Authentication fixtures

/// A throwaway RSA keypair, generated for this test suite and used nowhere else.
///
/// `configure` skips the tenant key fetch under `.testing`, so tokens are signed with this half
/// and verified against its public half. No test touches a live tenant, and no real Tapis key
/// appears in the repository.
enum TestKeys {
  static let privatePEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC24UpEcK5ckQLa
    O+l2KNTotE9rOmffJsEzg8BNiwh3dbAMA7XrXCREBPOq6FSF6Rm9VxaGjtH1TIHl
    gFvYhDiqO5eeFVllI8KNsCIKoeT8SkUPTskDc209MmoBdBU8sRtD/Tqk9La6gblb
    4liimjxEjb3x1xOY1ZxLoEdPZsDXPaLYR9lX3BrcKUiBZxDdV5qw3X0RxLfaAPmy
    Mkp3Dot5N0LZKDK2Mn0eQlS/2ZaX8JE6DYP1uZAXgmnbaKw/nG8chjVshPeTd/X9
    a8FkVHH9tzWye31zn56wLfeZje5MCfZG2L1JF23ZrF0rwwf6rhhHDDSoHqZ2eErL
    FBJ+ie5HAgMBAAECggEABfaYrlyiQuBzoFwdw72XG7Ntd4ijBHLGEAD2z1B+SS7s
    O6gPUYpioFks/OCwiOFN9o+Va3PSwtXo0mv6ErhVBLAGxJ/bl2GwIWCh64jV56gg
    Ulx2T4d/A2TWcg+v9Zes1O238NMN9kzul2FtFHhFCNM6Y11pBS3J9+lVCfDGzv3k
    aeZSx9DEv2gMJhch0EKixWeHu0X83swSw57LFylp7SVdJ5H06nF81KRVqzeTpIkk
    AkXpwqo+Vq7KiPBpi26H1/V69Vx5FhG+43pFWV7XzoU3DwlEf4KHy6kRTfKP1Khj
    tGqdsZxhyByUOrrHUd3FPp4pqNQ52pzBvY/L0BoFMQKBgQDadCW1ku9I3TzV82Jc
    cDWV91xADRqrbiWBTB7FLSXHy7d9zzr5GIfhuV1jU/Iljzjt9tC4lUaa4Lhf1x69
    h/QbAToFQpezbLHY5CXN3mLicC+AvPcuQBakYN9QHsdjD77Ie1nk+kQtg7sx/Kiz
    EVEqWW0kfYluiYpXAsbdYvYdaQKBgQDWT+tun7kfH0rmBQ9gw1SwBn8Q1nUVEn9m
    tLbVrQnRJbzUJAdILs792W8l8eycBtOatSvHmAh14bhIlOL4rdNNOD+9TNriVaIu
    M9ky7/A4x0SsLxlE7PkRhuh5W2fQNesPgp9LwyLeC6Bi+Jh4DcUEZynfDT8+iJaz
    LN1GXs1ILwKBgQCVGDp4b51i1KRlvaP/RRI9lULf8FGoeRed5I8HsiWb9Dz638n3
    Irfy5imH1k5pNhP7zb1sjW1P3VnZB6BSaQzAtZic6HNTITdMuYHXvRUuSLUTH2Vw
    qosJi5g+PZOF18Q1XoLfFbQcgFDt7+xPstz7k2c7RXbb+4Fwm1OQ267wKQKBgAk3
    6NWaUzkufGdGgnHUFRl5Pg/4WZLtd8NwNIkeZ1SyvduWLSYCtW6f4rMMI/RWKtX1
    wwtT09FWQzoEBXtS5srkh4FaA/RGYLKCEm6peXjHwYFyiTC4zMHfPrKxptaC6ziA
    kt+MZjyM3XpEXTKUzQuycE+i3zyOXYUZge8b9tKLAoGBAJVqlvgP9v1Cbjq6784i
    lBUouUbeZkRM8g9xPbZn0T76CLhMpkeaj3FCCZuJa69BRgHwQMhc6k4NZZFkzxHX
    xMks7DVg46iqZP9zNCJkIzFQsgmRA1Z7YeRorSTiFbeMgXR6saR5DILCSQkmK9Rf
    Qz39svlpQoRgWYdH3kEzqa5h
    -----END PRIVATE KEY-----
    """

  /// The public half of ``privatePEM``, body only, for exercising PEM normalization.
  static let publicPEMBody = """
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtuFKRHCuXJEC2jvpdijU
    6LRPazpn3ybBM4PATYsId3WwDAO161wkRATzquhUhekZvVcWho7R9UyB5YBb2IQ4
    qjuXnhVZZSPCjbAiCqHk/EpFD07JA3NtPTJqAXQVPLEbQ/06pPS2uoG5W+JYopo8
    RI298dcTmNWcS6BHT2bA1z2i2EfZV9wa3ClIgWcQ3VeasN19EcS32gD5sjJKdw6L
    eTdC2SgytjJ9HkJUv9mWl/CROg2D9bmQF4Jp22isP5xvHIY1bIT3k3f1/WvBZFRx
    /bc1snt9c5+esC33mY3uTAn2Rti9SRdt2axdK8MH+q4YRww0qB6mdnhKyxQSfonu
    RwIDAQAB
    """

  /// A second keypair, used only to prove a correctly formed token signed by the wrong issuer
  /// is rejected.
  static let foreignPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCAbYR91Dy6XjxG
    p31bZp0W3gbCL/O/RXXPfNfJ4uEfHgLzQW3mib3mI7l7cNwDIsGCvPubsFRAwf6e
    QrwkpUX22n7VCmf4JVyaJG7pdQ+c/EKJz/cDbBj9lf1DhKbk9oGnRxSfSVY1b7Aa
    9qIl7+EiP39iuuKd1Ure7v2iZK6kDT9PkA5VntJ/MeX/KKCb1EcXua+BGyY4ANvK
    4HkJ99ZQ6rnJZO5jqw/TTw3O6+yTgcWwrKRLXWhNSmlnW148C+3Blf1PaTGo1Ph/
    5jYpQuU2JN6uVM9uf/tnct4ZyZck4W5esK7UgY8uSTv4g7DdbejTWNW5ey1iBXRC
    9FXO7q4hAgMBAAECggEAAp5ZCHjCmTkxKO6i0XGE6/GweRahtWls5sNgofrohKon
    vL59h2kREGdzkXcCYWT8xZXlWm4MtbpO3vq029lr1QXs9pqM9qQKYJE0Grn6jMSe
    9bDiFDWIx+jePlluzrXQ/HBoVPwZkCLcGBylvzjGIhzh08lENBwkd+mvDbfYULt2
    BVsRx9ConK4BKiIk25ro2vTepZsnhXN1iLkWVvTkIa2YpngvyUON4rxffsEAOgc0
    m3yE/9fwQMnzB+F+i5hSYiWkpeWNpSgexanxrWUOQDRoS4ku2fg18UeeVm1vtJP8
    CJ6q/G5mxtoXIU7ruzuAq3zGQsqY5w08vaKTHgSebQKBgQC1XoRw0SOT4eCwy1mW
    2JaG8xV6fDsmoSm3PMUD1bROidBkz4qq0w78vNvLOujDO/8d+eHoKitT3WwLDppq
    j0Qj9mdwuXW0O1STg/54PXTG4DwagCSF3ll7onvcGQDfIsANr7LQ6eoE44dLMq66
    jllrWrYqBE7rJsPjGDFLM7DVxQKBgQC1RiNMHiQW2DS9cBj9dCmwppYCo012Zaff
    gNEpCtaNRb35lExNJ0VOwenaMK2sFxqyT1ygYG3h6W+S0xLFZBnWQJ2oTzgdpRre
    xmmqBw+QOnuc9xC++ROxcEZAf13WzVyBwlnB7TMo651+5bhos4T3gpu564NkEJpC
    yXlgzNDYrQKBgDClW0yPK8W8bfG9eRgWm7kyde5WZ98ilvfI2ub+aNAv8q83Y3AS
    EBEF7sYB1PCYpQK7RTZqKRjjaNlGX3B5YMNska4QcFuZFkRCwPwrL6kv967788/c
    JZAdsq8EHdG7lluVZpbWRqhtBprKy0bKa3155SY75Zb43M2KbZ5IDQQpAoGBAK0b
    2q9hBUPPmqXhu+uml/17SDwiqOHM+EBnKtbP484rcN07cpYnT3eDlQfpfqCdu7/W
    K/V3wNeBbiw/Z2ibTFUfha9qX4Nn3T4rKlLVxVYNk2h1REerYtQLDPug5gMwQAwm
    hkK8eyOzxcaeJ7nM3cjjsEUfFG1lsXrgHgqD7VlNAoGAcCd1Rt9wX6aRhc/8sHXp
    FmfqYb2DR1Jo9VBB+KNYfTklGYK1Jxsc7uzqRZpJicvMce0Tf198tZ56jwr67RUu
    vKNZ2XsPqxNziy/OH10Jskq3fBPasSehJQ58nhzrjfNrADTR0O8PJcqw4ilYd/oj
    +D1Xr49v3NY6Zelh7XkTCJo=
    -----END PRIVATE KEY-----
    """
}

extension Application {
  private struct TestAdminTokenKey: StorageKey { typealias Value = String }
  private struct TestUserTokenKey: StorageKey { typealias Value = String }

  /// Bearer token for the root admin.
  ///
  /// Signed for `app.rootAdmin`, so it holds access without the `admins` table being written to.
  /// Tests covering *granted* access call ``makeAdmin(on:username:addedBy:)`` and sign their own.
  var adminToken: String {
    get { storage[TestAdminTokenKey.self] ?? "" }
    set { storage[TestAdminTokenKey.self] = newValue }
  }

  /// Bearer token for an authenticated human who is *not* an admin.
  var userToken: String {
    get { storage[TestUserTokenKey.self] ?? "" }
    set { storage[TestUserTokenKey.self] = newValue }
  }

  /// Headers for an admin, who satisfies every requirement.
  var adminAuth: HTTPHeaders { ["Authorization": "Bearer \(adminToken)"] }

  /// Headers for a signed-in non-admin — authenticated, so refusals are 403 rather than 401.
  var userAuth: HTTPHeaders { ["Authorization": "Bearer \(userToken)"] }

}

/// Whether `TAPIS_TOKEN` holds a credential that could actually authenticate right now.
///
/// A handful of `VaultControllerTests` reach a real Tapis Vault, because the adapter needs real
/// credentials even to fail usefully — they write and destroy secrets rather than asserting
/// against a stub. Without this they fail with 500s wherever no usable token is configured, which
/// is indistinguishable from a genuine regression and makes the suite unusable in CI.
///
/// Needs no configuration in either direction: point `.env` at the staging tenant and they run,
/// leave the token blank and they skip.
///
/// **Expiry is checked, not just shape.** Tapis tokens last hours, so "looks like a JWT" is not
/// the same question as "will authenticate" — and an expired one produces exactly the confusing
/// 500s this exists to prevent. The signature is deliberately *not* verified: this decides whether
/// running the test is worthwhile, not whether the token is trustworthy, and the server it is
/// presented to makes that judgement itself.
var hasLiveTapisCredentials: Bool {
  guard let expiry = tapisTokenExpiry(Environment.get("TAPIS_TOKEN")) else { return false }
  return expiry > Date()
}

/// Reads `exp` out of a JWT payload, or nil when the value is not a JWT carrying one.
private func tapisTokenExpiry(_ token: String?) -> Date? {
  let segments = (token ?? "").split(separator: ".")
  guard segments.count == 3 else { return nil }

  // base64url differs from base64 in two characters and omits the padding Data requires.
  var encoded =
    String(segments[1])
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)

  guard
    let data = Data(base64Encoded: encoded),
    let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let exp = claims["exp"] as? TimeInterval
  else {
    return nil
  }

  return Date(timeIntervalSince1970: exp)
}

/// The HMAC secret webhook tokens are signed with in tests. Fixed rather than generated so a
/// failing assertion is readable.
let testSigningKey = "test-webhook-signing-key-not-a-real-secret"

/// The `kid` the test signing key is registered under.
let testSigningKid = "test-kid"

/// Registers the Tapis test key and the webhook signing keyset.
///
/// Runs after `configure`, which under `.testing` deliberately skips both the tenant key fetch
/// and the Vault read for the keyset rather than reaching the network.
func installTestCredentials(on app: Application) async throws {
  try await app.jwt.keys.add(
    rsa: Insecure.RSA.PrivateKey(pem: TestKeys.privatePEM),
    digestAlgorithm: .sha256
  )

  let serviceKeys = JWTKeyCollection()
  await serviceKeys.add(
    hmac: .init(from: testSigningKey), digestAlgorithm: .sha256,
    kid: .init(string: testSigningKid))
  app.serviceTokenKeys = serviceKeys
  app.activeSigningKid = testSigningKid

  app.adminToken = try await signTapisToken(on: app, username: app.rootAdmin)
  app.userToken = try await signTapisToken(on: app, username: "not-an-admin")
}

/// Mints a real webhook token through ``ServiceTokenIssuer``, so tests exercise the same path
/// the CLI and the controller do rather than a parallel fixture that could drift.
func issueWebhookToken(
  on app: Application,
  resourceID: Resource.IDValue,
  label: String = "test-service",
  lifetimeInDays: Int? = nil,
) async throws -> ServiceTokenIssuer.Issued {
  try await ServiceTokenIssuer(
    db: app.db, keys: app.serviceTokenKeys, activeKid: app.activeSigningKid
  ).mint(
    resourceID: resourceID,
    label: label,
    lifetimeInDays: lifetimeInDays,
  )
}

/// Signs a webhook token directly, bypassing the issuer, so a test can produce one that no
/// legitimate path would: expired, foreign-issuer, or signed with the wrong key.
func signWebhookToken(
  resourceID: Resource.IDValue,
  jti: UUID = UUID(),
  issuer: String = WebhookToken.issuerValue,
  expires: Date = Date().addingTimeInterval(3600),
  key: String = testSigningKey,
) async throws -> String {
  let keys = JWTKeyCollection()
  await keys.add(
    hmac: .init(from: key), digestAlgorithm: .sha256, kid: .init(string: testSigningKid))

  return try await keys.sign(
    WebhookToken(
      issuer: .init(value: issuer),
      tokenID: .init(value: jti.uuidString),
      issuedAt: .init(value: Date()),
      expiration: .init(value: expires),
      resourceID: resourceID,
    ),
    kid: .init(string: testSigningKid),
  )
}

/// Grants admin access to a username through the table, as the dashboard would.
@discardableResult
func makeAdmin(
  on db: any Database,
  username: String,
  addedBy: String = "test-root",
) async throws -> Admin {
  let admin = Admin(username: username, addedBy: addedBy)
  try await admin.create(on: db)
  return admin
}

/// Bearer headers for an arbitrary token value.
func bearer(_ token: String) -> HTTPHeaders {
  ["Authorization": "Bearer \(token)"]
}

/// Signs a Tapis-shaped token with the test key.
func signTapisToken(
  on app: Application,
  username: String,
  tenant: String? = nil,
  expires: Date = Date().addingTimeInterval(3600),
  key: String = TestKeys.privatePEM,
) async throws -> String {
  let payload = TapisToken(
    tenant: tenant ?? app.tapisConfig.tenant,
    username: username,
    accountType: "user",
    expiration: .init(value: expires),
  )

  // A key other than the tenant's gets its own collection: adding it to `app.jwt.keys` would
  // make it a *trusted* signer, which is the opposite of what those tests assert.
  guard key != TestKeys.privatePEM else {
    return try await app.jwt.keys.sign(payload)
  }

  let foreign = JWTKeyCollection()
  await foreign.add(rsa: try Insecure.RSA.PrivateKey(pem: key), digestAlgorithm: .sha256)
  return try await foreign.sign(payload)
}

/// A `SecretProvider` backed by a dictionary, so key rotation can be exercised without a live
/// Vault. The Tapis adapter needs real credentials even to fail usefully.
final class InMemorySecrets: SecretProvider, @unchecked Sendable {
  private let storage = NIOLockedValueBox<[String: String]>([:])

  init(_ initial: [String: String] = [:]) {
    storage.withLockedValue { $0 = initial }
  }

  func readSecret(named name: String) async throws -> Secret {
    guard let value = storage.withLockedValue({ $0[name] }) else {
      throw TapisClientError.secretNotFound(name: name)
    }
    return Secret(value)
  }

  func writeSecret(named name: String, secret: String) async throws {
    storage.withLockedValue { $0[name] = secret }
  }

  func destroySecret(named name: String) async throws {
    storage.withLockedValue { $0[name] = nil }
  }
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

/// `stubAPI` for endpoints whose *query* decides the answer.
///
/// `StubRoute` deliberately ignores the query string so the Hub's `expand[]` can vary freely.
/// Paging is the opposite case: `?skip=0` and `?skip=100` must answer differently, or a loop
/// that never advances still passes.
///
/// `respond` sees the full URL, so it can switch on the query itself — building bodies with the
/// same private `jsonResponse` helper `stubAPI` uses — and returns `nil` for anything it does not
/// recognize. Matches `stubAPI`'s other two contracts: both `app.client` and `app.secrets` are
/// replaced (`configure` builds the Tapis adapter from `app.client` at boot, so swapping only the
/// client factory would leave it holding the real one), and a `nil` answers 404, so a job asking
/// for a URL the test did not anticipate surfaces rather than silently succeeding.
@discardableResult
func stubPagedAPI(
  on app: Application,
  _ respond: @escaping @Sendable (String) -> ClientResponse?
) -> NIOLockedValueBox<[ClientRequest]> {
  let requests = NIOLockedValueBox<[ClientRequest]>([])
  let stub = StubHTTPClient(eventLoop: app.eventLoopGroup.any(), requests: requests) { request in
    respond(request.url.string) ?? ClientResponse(status: .notFound)
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

// MARK: - stubPagedAPI

/// A minimal decodable used only to prove `stubPagedAPI` round-trips a body; no production type
/// depends on it.
private struct StubPagedCard: Content, Equatable {
  let uuid: String
}

/// Exercises `stubPagedAPI` directly, without a job or collector in front of it — none exists
/// yet for a paginated platform, and this helper should not need one to be trustworthy.
@Suite("stubPagedAPI")
struct StubPagedAPITests {
  /// The case `StubRoute` cannot express: two requests share a path and differ only by `skip`.
  /// Against the old, path-only `stubAPI` these would collide on one registered route and the
  /// second page would silently repeat the first — a pagination loop that never advances would
  /// still pass. Asserting the bodies differ is what makes that regression visible.
  @Test
  func `Two skips on the same path answer with two different bodies`() async throws {
    try await withInsightsApp { app in
      let requests = stubPagedAPI(on: app) { url in
        if url.contains("skip=0") { return jsonResponse(.ok, #"[{"uuid":"first"}]"#) }
        if url.contains("skip=100") { return jsonResponse(.ok, #"[{"uuid":"second"}]"#) }
        return nil
      }

      let firstPage = try await app.client.get(
        URI(string: "https://patra.example/modelcards?skip=0&limit=100"))
      let secondPage = try await app.client.get(
        URI(string: "https://patra.example/modelcards?skip=100&limit=100"))

      #expect(firstPage.status == .ok)
      #expect(secondPage.status == .ok)
      #expect(try firstPage.content.decode([StubPagedCard].self) == [StubPagedCard(uuid: "first")])
      #expect(
        try secondPage.content.decode([StubPagedCard].self) == [StubPagedCard(uuid: "second")])
      #expect(requests.withLockedValue { $0.count } == 2)
    }
  }

  /// Matches `stubAPI`'s contract: a query `respond` does not recognize answers 404 rather than
  /// succeeding silently, so a job asking for a page this test forgot to describe fails loudly.
  @Test
  func `An unrecognized query answers 404`() async throws {
    try await withInsightsApp { app in
      stubPagedAPI(on: app) { _ in nil }

      let response = try await app.client.get(
        URI(string: "https://patra.example/modelcards?skip=0&limit=100"))

      #expect(response.status == .notFound)
    }
  }
}
