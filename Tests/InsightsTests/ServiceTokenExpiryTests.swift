import Fluent
import Foundation
import Testing
import Vapor

@testable import Insights

/// The daily sweep that warns before a webhook token lapses.
///
/// Serialized alongside the rest: it boots an application and shares the `test` database.
@Suite("Service token expiry warnings", .serialized)
struct ServiceTokenExpiryTests {

  /// Creates a live token expiring `days` from now, bypassing the issuer so the expiry can be
  /// placed anywhere — the issuer only mints forward from today.
  @discardableResult
  private func makeToken(
    on db: any Database,
    resourceID: Resource.IDValue,
    label: String,
    expiringInDays days: Double,
    revoked: Bool = false,
  ) async throws -> ServiceToken {
    let token = ServiceToken(
      jti: UUID(),
      resourceID: resourceID,
      label: label,
      expiresAt: Date().addingTimeInterval(days * 86_400),
      revokedAt: revoked ? Date() : nil,
    )
    try await token.create(on: db)
    return token
  }

  private func sweep(_ app: Application) async throws {
    try await WarnExpiringServiceTokens().run(context: queueContext(for: app))
  }

  @Test(arguments: WarnExpiringServiceTokens.warnAtDaysRemaining)
  func `Each threshold produces exactly one alert`(threshold: Int) async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let notifier = stubNotifier(on: app)

      // A hair under the threshold, since `daysRemaining` rounds up — this is what a token
      // actually looks like partway through the day the sweep catches it.
      try await makeToken(
        on: app.db, resourceID: try resource.requireID(), label: "prod",
        expiringInDays: Double(threshold) - 0.5)

      try await sweep(app)

      #expect(notifier.recorded.count == 1)
      #expect(notifier.recorded.first?.details.contains("\(threshold) day") == true)
    }
  }

  @Test
  func `A token between thresholds stays quiet`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let notifier = stubNotifier(on: app)

      // 10 days is inside the widest threshold but is not itself one. Alerting here would mean
      // alerting every day for a fortnight, which is how a channel gets muted.
      try await makeToken(
        on: app.db, resourceID: try resource.requireID(), label: "prod", expiringInDays: 9.5)

      try await sweep(app)

      #expect(notifier.recorded.isEmpty)
    }
  }

  @Test
  func `A token far from expiry is never queried`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let notifier = stubNotifier(on: app)

      try await makeToken(
        on: app.db, resourceID: try resource.requireID(), label: "prod", expiringInDays: 60)

      try await sweep(app)

      #expect(notifier.recorded.isEmpty)
    }
  }

  @Test
  func `A revoked token is not warned about`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let notifier = stubNotifier(on: app)

      // Retired deliberately. Warning that it is about to expire describes something nobody is
      // relying on.
      try await makeToken(
        on: app.db, resourceID: try resource.requireID(), label: "retired",
        expiringInDays: 0.5, revoked: true)

      try await sweep(app)

      #expect(notifier.recorded.isEmpty)
    }
  }

  @Test
  func `An already expired token is not warned about`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let notifier = stubNotifier(on: app)

      // The warning exists to prevent a lapse. After the fact it is noise about something that
      // has already stopped working.
      try await makeToken(
        on: app.db, resourceID: try resource.requireID(), label: "lapsed", expiringInDays: -1)

      try await sweep(app)

      #expect(notifier.recorded.isEmpty)
    }
  }

  @Test
  func `Urgency escalates as the deadline approaches`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let notifier = stubNotifier(on: app)

      try await makeToken(
        on: app.db, resourceID: resourceID, label: "distant", expiringInDays: 13.5)
      try await makeToken(
        on: app.db, resourceID: resourceID, label: "imminent", expiringInDays: 0.5)

      try await sweep(app)

      let bySubject = Dictionary(
        uniqueKeysWithValues: notifier.recorded.map { ($0.subject, $0.severity) })

      #expect(bySubject.count == 2)
      // A fortnight's notice is something to schedule; a day's notice is something to do now.
      #expect(bySubject["\(resource.name) (distant)"] == .warning)
      #expect(bySubject["\(resource.name) (imminent)"] == .critical)
    }
  }

  @Test
  func `The alert names the resource and how to reissue`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let notifier = stubNotifier(on: app)

      try await makeToken(
        on: app.db, resourceID: resourceID, label: "prod-inference", expiringInDays: 6.5)

      try await sweep(app)

      let alert = try #require(notifier.recorded.first)
      // An alert that says only "a token is expiring" sends the reader hunting for which one.
      #expect(alert.subject.contains(resource.name))
      #expect(alert.subject.contains("prod-inference"))
      #expect(alert.details.contains(resourceID.uuidString))
      #expect(alert.details.contains("service-token issue"))
    }
  }

  @Test
  func `Rounding up keeps a token from slipping between thresholds`() {
    let now = Date()

    // 6.4 days truncates to 6, which is not a threshold — the warning would be skipped entirely
    // even though the token is squarely inside the 7-day window.
    #expect(
      WarnExpiringServiceTokens.daysRemaining(from: now, to: now.addingTimeInterval(6.4 * 86_400))
        == 7)
    #expect(
      WarnExpiringServiceTokens.daysRemaining(from: now, to: now.addingTimeInterval(0.1 * 86_400))
        == 1)
    #expect(
      WarnExpiringServiceTokens.daysRemaining(from: now, to: now.addingTimeInterval(13.5 * 86_400))
        == 14)
  }
}
