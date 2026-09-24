import Foundation
import Testing
import Vapor

@testable import Insights

/// Reading `TAPIS_TOKEN`'s own expiry, and the daily warning ahead of it.
///
/// Every token here is crafted and unsigned. The reader deliberately does not verify signatures,
/// so a test token needs no key, and none of these can authenticate anywhere.
@Suite("Tapis token expiry", .serialized)
struct TapisTokenExpiryTests {
  /// An unsigned JWT whose payload is `claims`, serialised as given.
  private func unsignedJWT(_ claims: String) -> String {
    func base64url(_ text: String) -> String {
      Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(base64url(#"{"alg":"none","typ":"JWT"}"#)).\(base64url(claims)).unsigned"
  }

  private func unsignedJWT(expiring expiry: Date) -> String {
    unsignedJWT(#"{"sub":"insights","exp":\#(Int(expiry.timeIntervalSince1970))}"#)
  }

  /// Runs the threshold check for a token expiring `days` from now.
  private func warn(_ app: Application, expiringInDays days: Double) async {
    let now = Date()
    await WarnExpiringTapisToken.warn(
      expiry: now.addingTimeInterval(days * 86_400),
      tenant: "icicleai",
      now: now,
      context: queueContext(for: app),
    )
  }

  // MARK: - Reading the claim

  @Test
  func `The expiry is read from an unsigned token's exp claim`() {
    let expiry = Date(timeIntervalSince1970: 1_790_000_000)
    #expect(TapisConfig.expiry(ofJWT: unsignedJWT(expiring: expiry)) == expiry)
  }

  /// CI runs with a placeholder, and nothing about a malformed value may fail the boot.
  @Test(arguments: [
    "ci-placeholder-not-a-jwt",
    "",
    "a.b.c",
    "only.two",
    "four.parts.are.wrong",
  ])
  func `A value that is not a JWT has no expiry`(value: String) {
    #expect(TapisConfig.expiry(ofJWT: value) == nil)
  }

  @Test
  func `A JWT without a numeric exp has no expiry`() {
    #expect(TapisConfig.expiry(ofJWT: unsignedJWT(#"{"sub":"insights"}"#)) == nil)
    #expect(TapisConfig.expiry(ofJWT: unsignedJWT(#"{"exp":"tomorrow"}"#)) == nil)
  }

  /// The configuration computes it once from the token it was given.
  @Test
  func `The configuration carries its token's expiry`() {
    let expiry = Date(timeIntervalSince1970: 1_790_000_000)
    let config = TapisConfig(
      baseURL: "https://icicleai.staging.tapis.io/v3",
      tenant: "icicleai",
      admin: TapisAdmin(name: "insights", token: unsignedJWT(expiring: expiry)),
    )
    #expect(config.tokenExpiry == expiry)
  }

  // MARK: - The daily warning

  @Test(arguments: [7, 3, 1])
  func `Each threshold produces exactly one alert`(threshold: Int) async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)

      // A hair under the threshold, since `daysRemaining` rounds up — what the token actually
      // looks like partway through the day the sweep catches it.
      await warn(app, expiringInDays: Double(threshold) - 0.5)

      #expect(notifier.recorded.count == 1)
      let alert = try #require(notifier.recorded.first)
      #expect(alert.identifier == "tapisToken.expiring")
      #expect(alert.details.contains("\(threshold) day"))
      #expect(alert.subject == "TAPIS_TOKEN (icicleai)")
      #expect(alert.severity == (threshold <= 3 ? .critical : .warning))
    }
  }

  /// Alerting every day of the final week is how a channel gets muted.
  @Test(arguments: [10.0, 5.5, 4.5, 1.5])
  func `A token between thresholds stays quiet`(days: Double) async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      await warn(app, expiringInDays: days)
      #expect(notifier.recorded.isEmpty)
    }
  }

  /// Once, critically: the first daily run after the lapse. Later runs read a negative remainder
  /// and stay quiet, because by then every collection is failing and alerting on its own.
  @Test
  func `An expired token alerts critically on the first run after, and only then`()
    async throws
  {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)

      await warn(app, expiringInDays: -0.5)
      let alert = try #require(notifier.recorded.first)
      #expect(alert.severity == .critical)
      #expect(alert.identifier == "tapisToken.expired")
      #expect(alert.details.contains("no account is being collected"))

      await warn(app, expiringInDays: -1.5)
      #expect(notifier.recorded.count == 1)
    }
  }

  /// The suite's own `.env` carries CI's placeholder, which is exactly the case to survive.
  @Test
  func `A placeholder token is skipped without failing the job`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      app.tapisConfig = TapisConfig(
        baseURL: app.tapisConfig.baseURL,
        tenant: app.tapisConfig.tenant,
        admin: TapisAdmin(name: "insights", token: "ci-placeholder-not-a-jwt"),
      )

      try await WarnExpiringTapisToken().run(context: queueContext(for: app))

      #expect(notifier.recorded.isEmpty)
    }
  }

  /// End to end through `run`, reading the token from the application's configuration.
  @Test
  func `The job reads the configured token`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      app.tapisConfig = TapisConfig(
        baseURL: app.tapisConfig.baseURL,
        tenant: app.tapisConfig.tenant,
        admin: TapisAdmin(
          name: "insights",
          token: unsignedJWT(expiring: Date().addingTimeInterval(2.5 * 86_400))),
      )

      try await WarnExpiringTapisToken().run(context: queueContext(for: app))

      #expect(notifier.recorded.map(\.severity) == [.critical])
      #expect(notifier.recorded.first?.details.contains("3 days") == true)
    }
  }
}
