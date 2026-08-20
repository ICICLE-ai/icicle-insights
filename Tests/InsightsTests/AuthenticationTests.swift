import Fluent
import Foundation
import Testing
import VaporTesting

@testable import Insights

/// Covers the two credential paths and, most importantly, where they cross.
///
/// The status codes are the contract: 401 means nobody could be authenticated, 403 means someone
/// was and lacks the grant. Collapsing the two would leak whether a token is real.
@Suite("Authentication", .serialized)
struct AuthenticationTests {

  // MARK: - Public reads

  @Test
  func `Anonymous reads stay open`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      _ = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
        },
      )
    }
  }

  @Test
  func `Anonymous vault reads are refused`() async throws {
    try await withInsightsApp { app in
      // Metadata only, but listing which credentials exist and when they expire is
      // reconnaissance, so the vault reads are admin-only unlike every other index route.
      try await app.testing().test(
        .GET,
        "api/vaults",
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  // MARK: - Tapis path

  @Test
  func `Admin token reaches an admin-only route`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)

      try await app.testing().test(
        .DELETE,
        "api/accounts/\(try account.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
        },
      )
    }
  }

  @Test
  func `Authenticated non-admin is refused with 403`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)

      try await app.testing().test(
        .DELETE,
        "api/accounts/\(try account.requireID())",
        headers: app.userAuth,
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
          #expect(try await Account.query(on: app.db).count() == 1)
        },
      )
    }
  }

  @Test
  func `Expired token is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let expired = try await signTapisToken(
        on: app,
        username: "test-admin",
        expires: Date().addingTimeInterval(-60),
      )

      try await app.testing().test(
        .DELETE,
        "api/accounts/\(try account.requireID())",
        headers: ["Authorization": "Bearer \(expired)"],
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  @Test
  func `Token signed by another keypair is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let forged = try await signTapisToken(
        on: app,
        username: "test-admin",
        key: TestKeys.foreignPEM,
      )

      try await app.testing().test(
        .DELETE,
        "api/accounts/\(try account.requireID())",
        headers: ["Authorization": "Bearer \(forged)"],
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  @Test
  func `Correctly signed token from another tenant is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      // Deliberately kept alongside the bad-signature test even though it looks redundant.
      // They fail for different reasons, and this is the one that regresses if someone later
      // decides the tenant comparison is unnecessary.
      let foreignTenant = try await signTapisToken(
        on: app,
        username: "test-admin",
        tenant: "some-other-tenant",
      )

      try await app.testing().test(
        .DELETE,
        "api/accounts/\(try account.requireID())",
        headers: ["Authorization": "Bearer \(foreignTenant)"],
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  @Test
  func `Bearer value that is not a JWT is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)

      try await app.testing().test(
        .DELETE,
        "api/accounts/\(try account.requireID())",
        headers: ["Authorization": "Bearer not-a-jwt"],
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  // MARK: - Webhook tokens

  @Test
  func `Scoped token posts metrics for its own resource`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 12, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let returned = try res.content.decode(Metric.Public.self)
          #expect(returned.resourceID == resourceID)
          #expect(returned.reading == 12)
        },
      )
    }
  }

  @Test
  func `Scoped token cannot post to another resource`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let mine = try await makeResource(on: app.db, accountID: try account.requireID())
      let theirs = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "other")
      let issued = try await issueWebhookToken(on: app, resourceID: try mine.requireID())

      // The whole point of the scoping: a perfectly valid token, refused because it is aimed
      // somewhere its holder was never granted.
      try await app.testing().test(
        .POST,
        "api/resources/\(try theirs.requireID())/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 99, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
          #expect(try await Metric.query(on: app.db).count() == 0)
        },
      )
    }
  }

  @Test
  func `Revoked token is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      let issuer = ServiceTokenIssuer(
        db: app.db, keys: app.serviceTokenKeys, activeKid: app.activeSigningKid)
      try await issuer.revoke(jti: issued.record.jti)

      // No restart, no cache to expire: the lookup is live, which is the entire reason the
      // database row exists alongside a self-contained token.
      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 1, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
          #expect(try await Metric.query(on: app.db).count() == 0)
        },
      )
    }
  }

  @Test
  func `Expired webhook token is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let expired = try await signWebhookToken(
        resourceID: resourceID, expires: Date().addingTimeInterval(-60))

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(expired),
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
  func `Token signed with the wrong key is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let forged = try await signWebhookToken(resourceID: resourceID, key: "not-the-real-key")

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(forged),
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
  func `Correctly signed token with an unknown jti is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      // Signature and claims are all valid; there is simply no row. That is what a deleted
      // token looks like, and it must not authenticate.
      let orphan = try await signWebhookToken(resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(orphan),
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
  func `Token from a foreign issuer is refused with 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let foreign = try await signWebhookToken(resourceID: resourceID, issuer: "somewhere-else")

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(foreign),
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
  func `Empty bearer value is refused with 401`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: ["Authorization": "Bearer "],
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )
    }
  }

  // MARK: - Crossover

  @Test
  func `Admin posts to the webhook route for any resource`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      // `Require.resourceScoped` checks admin first; without that a human would be locked out
      // of every route a deployed service can reach.
      try await app.testing().test(
        .POST,
        "api/resources/\(try resource.requireID())/metrics",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 7, type: .stars))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
        },
      )
    }
  }

  @Test
  func `Webhook token on an admin route is 403 rather than 401`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let issued = try await issueWebhookToken(on: app, resourceID: try resource.requireID())

      // The distinction matters: the caller is genuinely authenticated, and reporting 401 would
      // suggest its credential is bad rather than insufficient.
      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: bearer(issued.token),
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
        },
      )
    }
  }

  @Test
  func `Webhook token cannot delete metrics`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let metric = try await makeMetric(on: app.db, resourceID: resourceID)
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      // A malfunctioning service should at worst write bad rows, never remove history.
      try await app.testing().test(
        .DELETE,
        "api/metrics/\(try metric.requireID())",
        headers: bearer(issued.token),
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
          #expect(try await Metric.query(on: app.db).count() == 1)
        },
      )
    }
  }

  // MARK: - Issuing

  @Test
  func `Minting revokes the resource's previous token`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()

      let first = try await issueWebhookToken(on: app, resourceID: resourceID, label: "old")
      let second = try await issueWebhookToken(on: app, resourceID: resourceID, label: "new")

      #expect(first.token != second.token)

      // One live credential per resource, always — a replaced token must not keep working.
      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(first.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 1, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
        },
      )

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(second.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 2, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
        },
      )
    }
  }

  @Test
  func `Minting for an unknown resource is a bad request`() async throws {
    try await withInsightsApp { app in
      let issuer = ServiceTokenIssuer(
        db: app.db, keys: app.serviceTokenKeys, activeKid: app.activeSigningKid)

      await #expect(throws: (any Error).self) {
        try await issuer.mint(resourceID: UUID(), label: "ghost")
      }
    }
  }

  @Test
  func `Deleting a resource takes its tokens with it`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      _ = try await issueWebhookToken(on: app, resourceID: try resource.requireID())

      #expect(try await ServiceToken.query(on: app.db).count() == 1)

      try await resource.delete(force: true, on: app.db)

      #expect(try await ServiceToken.query(on: app.db).count() == 0)
    }
  }
}
