import Fluent
import Foundation
import Testing
import VaporTesting

@testable import Insights

/// The dashboard's half of token administration. It shares `ServiceTokenIssuer` with the CLI, so
/// these cover the HTTP surface rather than re-testing the minting rules.
@Suite("Service Token Controller", .serialized)
struct ServiceTokenControllerTests {

  @Test
  func `Mint returns the token exactly once`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()

      var minted: ServiceToken.Minted?

      try await app.testing().test(
        .POST,
        "api/service-tokens",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(
            ServiceToken.Create(
              resourceID: resourceID, label: "prod-inference", expiresInDays: nil))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let body = try res.content.decode(ServiceToken.Minted.self)
          #expect(!body.token.isEmpty)
          #expect(body.endpoint == "/api/resources/\(resourceID)/metrics")
          #expect(body.serviceToken.label == "prod-inference")
          #expect(body.serviceToken.revokedAt == nil)
          minted = body
        },
      )

      // The token is returned by that one response and nowhere else — no route reads it back.
      let issued = try #require(minted)
      try await app.testing().test(
        .GET,
        "api/service-tokens",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          #expect(!res.body.string.contains(issued.token))
        },
      )
    }
  }

  @Test
  func `Minted token works against its resource`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()

      var token = ""

      try await app.testing().test(
        .POST,
        "api/service-tokens",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(
            ServiceToken.Create(resourceID: resourceID, label: "prod", expiresInDays: nil))
        },
        afterResponse: { res async throws in
          token = try res.content.decode(ServiceToken.Minted.self).token
        },
      )

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 5, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
        },
      )
    }
  }

  @Test
  func `Revoke over HTTP stops the token`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/service-tokens/\(try issued.record.requireID())/revoke",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          #expect(try res.content.decode(ServiceToken.Public.self).revokedAt != nil)
        },
      )

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 1, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  @Test
  func `Revoked rows are retained for audit`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let issued = try await issueWebhookToken(on: app, resourceID: try resource.requireID())

      try await app.testing().test(
        .POST,
        "api/service-tokens/\(try issued.record.requireID())/revoke",
        headers: app.adminAuth,
        afterResponse: { res async throws in #expect(res.status == .ok) },
      )

      // Revoke, not delete: the record of what was issued and when it stopped working outlives
      // the credential itself.
      try await app.testing().test(
        .GET,
        "api/service-tokens",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          let listed = try res.content.decode([ServiceToken.Public].self)
          #expect(listed.count == 1)
          #expect(listed.first?.revokedAt != nil)
        },
      )
    }
  }

  @Test
  func `A non-admin cannot mint`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/service-tokens",
        headers: app.userAuth,
        beforeRequest: { req in
          try req.content.encode(
            ServiceToken.Create(
              resourceID: try resource.requireID(), label: "sneaky", expiresInDays: nil))
        },
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
          #expect(try await ServiceToken.query(on: app.db).count() == 0)
        },
      )
    }
  }

  @Test
  func `A webhook token cannot mint another`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      // Otherwise a leaked webhook token would be a credential-minting oracle.
      try await app.testing().test(
        .POST,
        "api/service-tokens",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(
            ServiceToken.Create(resourceID: resourceID, label: "escalate", expiresInDays: nil))
        },
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
          #expect(try await ServiceToken.query(on: app.db).count() == 1)
        },
      )
    }
  }

  @Test
  func `Anonymous callers cannot list tokens`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/service-tokens",
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  @Test
  func `Revoking an unknown token is a not found`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .POST,
        "api/service-tokens/\(UUID())/revoke",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .notFound)
        },
      )
    }
  }

  @Test
  func `Mint rejects a blank label`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/service-tokens",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(
            ServiceToken.Create(
              resourceID: try resource.requireID(), label: "   ", expiresInDays: nil))
        },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          #expect(try await ServiceToken.query(on: app.db).count() == 0)
        },
      )
    }
  }
}
