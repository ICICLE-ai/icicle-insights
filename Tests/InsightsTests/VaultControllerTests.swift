import Fluent
import Foundation
import Testing
import VaporTesting

@testable import Insights

@Suite("Vault Controller", .serialized)
struct VaultControllerTests {
  /// Writes and destroys a real secret, so it needs live Tapis credentials. Skipped rather
  /// than failed when none are configured — see `hasLiveTapisCredentials`.
  @Test(.enabled(if: hasLiveTapisCredentials))
  func `Create derives the name from platform and account`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "Octo Cat", platform: .github)
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: futureExpires(),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let returned = try res.content.decode(Vault.Public.self)
          // The account itself lowercases and trims on create, so "Octo Cat" is already
          // "octo cat" by the time the vault name is derived from it.
          #expect(returned.name == "insights-github-octo-cat")
          #expect(returned.accountID == account.id)
        },
      )
    }
  }

  @Test
  func `Create with missing account is a bad request`() async throws {
    try await withInsightsApp { app in
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: UUID(),
        expires: futureExpires(),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let count = try await Vault.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Create maps an upstream 5xx to 502`() async throws {
    try await withInsightsApp { app in
      stubTapis(on: app, status: .serviceUnavailable)
      let account = try await makeAccount(on: app.db)
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: Vault.Expires(day: 31, month: 12, year: 2026),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badGateway)
        },
      )
    }
  }

  @Test
  func `Create maps an upstream 4xx to 500`() async throws {
    try await withInsightsApp { app in
      stubTapis(on: app, status: .unauthorized)
      let account = try await makeAccount(on: app.db)
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: Vault.Expires(day: 31, month: 12, year: 2026),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .internalServerError)
        },
      )
    }
  }

  @Test
  func `Create rolls back the vault row when the secret write fails`() async throws {
    try await withInsightsApp { app in
      stubTapis(on: app, status: .serviceUnavailable)
      let account = try await makeAccount(on: app.db)
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: Vault.Expires(day: 31, month: 12, year: 2026),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badGateway)
          let count = try await Vault.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Index returns all vaults`() async throws {
    try await withInsightsApp { app in
      let first = try await makeAccount(on: app.db, name: "alpha")
      let second = try await makeAccount(on: app.db, name: "beta", platform: .npm)
      _ = try await makeVault(on: app.db, accountID: try first.requireID(), name: "alpha-token")
      _ = try await makeVault(on: app.db, accountID: try second.requireID(), name: "beta-token")

      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let names = try res.content.decode([Vault.Public].self).compactMap(\.name).sorted()
          #expect(names == ["alpha-token", "beta-token"])
        },
      )
    }
  }

  @Test
  func `Show vault by ID`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let vault = try await makeVault(on: app.db, accountID: try account.requireID())
      let vaultID = try vault.requireID()

      try await app.testing().test(
        .GET,
        "api/vaults/\(vaultID)",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Vault.Public.self)
          #expect(returned.id == vaultID)
        },
      )
    }
  }

  /// Writes and destroys a real secret, so it needs live Tapis credentials. Skipped rather
  /// than failed when none are configured — see `hasLiveTapisCredentials`.
  @Test(.enabled(if: hasLiveTapisCredentials))
  func `Update sets the expiration date`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let vault = try await makeVault(on: app.db, accountID: try account.requireID())

      let expires = futureExpires()
      let update = Vault.Update(token: "ghp_rotated", expires: expires)
      try await app.testing().test(
        .PATCH,
        "api/vaults/\(vault.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(update) },
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let model = try #require(await Vault.find(vault.requireID(), on: app.db))
          let expiresAt = try #require(model.expiresAt)
          let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: expiresAt)
          #expect(components.year == expires.year)
          #expect(components.month == expires.month)
          #expect(components.day == expires.day)
        },
      )
    }
  }

  @Test
  func `Create rejects a blank token`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Vault.Create(
        token: "",
        accountID: try account.requireID(),
        expires: futureExpires(),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let count = try await Vault.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Create rejects an out of range expiration day`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: Vault.Expires(day: 32, month: 12, year: 2099),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let count = try await Vault.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Create rejects an expiration in the past`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: Vault.Expires(day: 1, month: 1, year: 1999),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let count = try await Vault.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Create rejects a second vault for the same account`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      // The derived name is deterministic per account, so a pre-existing vault for the same
      // account always collides — there is no longer a distinct "name" to vary.
      _ = try await makeVault(
        on: app.db, accountID: try account.requireID(),
        name: Vault.credentialName(platform: account.platform, accountName: account.name))

      let payload = Vault.Create(
        token: "ghp_example",
        accountID: try account.requireID(),
        expires: futureExpires(),
      )

      try await app.testing().test(
        .POST,
        "api/vaults",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .conflict)
          let count = try await Vault.query(on: app.db).count()
          #expect(count == 1)
        },
      )
    }
  }

  @Test
  func `Update rejects a blank token`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let vault = try await makeVault(on: app.db, accountID: try account.requireID())

      let update = Vault.Update(token: " ", expires: futureExpires())
      try await app.testing().test(
        .PATCH,
        "api/vaults/\(vault.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(update) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let model = try #require(await Vault.find(vault.requireID(), on: app.db))
          #expect(model.expiresAt == nil)
        },
      )
    }
  }

  @Test
  func `Update rejects an expiration in the past`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let vault = try await makeVault(on: app.db, accountID: try account.requireID())

      let update = Vault.Update(
        token: "ghp_rotated", expires: Vault.Expires(day: 1, month: 1, year: 1999))
      try await app.testing().test(
        .PATCH,
        "api/vaults/\(vault.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(update) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let model = try #require(await Vault.find(vault.requireID(), on: app.db))
          #expect(model.expiresAt == nil)
        },
      )
    }
  }

  /// Writes and destroys a real secret, so it needs live Tapis credentials. Skipped rather
  /// than failed when none are configured — see `hasLiveTapisCredentials`.
  @Test(.enabled(if: hasLiveTapisCredentials))
  func `Delete vault`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let vault = try await makeVault(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .DELETE,
        "api/vaults/\(vault.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
          let model = try await Vault.find(vault.id, on: app.db)
          #expect(model == nil)
        },
      )
    }
  }
}
