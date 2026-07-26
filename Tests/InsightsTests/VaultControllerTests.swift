import Fluent
import Foundation
@testable import Insights
import Testing
import VaporTesting

@Suite("Vault Controller", .serialized)
struct VaultControllerTests {
    @Test
    func `Create derives the name from the account`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let payload = Vault.Create(
                token: "ghp_example",
                accountID: try account.requireID(),
                expires: Vault.Expires(day: 31, month: 12, year: 2026),
            )

            try await app.testing().test(
                .POST,
                "vaults",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .created)
                    let returned = try res.content.decode(Vault.Public.self)
                    #expect(returned.name == "octocat-github-api-token")
                    #expect(returned.accountID == account.id)
                },
            )
        }
    }

    @Test
    func `Create with missing account is a bad request`() async throws {
        try await withApp { app in
            let payload = Vault.Create(
                token: "ghp_example",
                accountID: UUID(),
                expires: Vault.Expires(day: 31, month: 12, year: 2026),
            )

            try await app.testing().test(
                .POST,
                "vaults",
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
        try await withApp { app in
            stubTapis(on: app, status: .serviceUnavailable)
            let account = try await makeAccount(on: app.db)
            let payload = Vault.Create(
                token: "ghp_example",
                accountID: try account.requireID(),
                expires: Vault.Expires(day: 31, month: 12, year: 2026),
            )

            try await app.testing().test(
                .POST,
                "vaults",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badGateway)
                },
            )
        }
    }

    @Test
    func `Create maps an upstream 4xx to 500`() async throws {
        try await withApp { app in
            stubTapis(on: app, status: .unauthorized)
            let account = try await makeAccount(on: app.db)
            let payload = Vault.Create(
                token: "ghp_example",
                accountID: try account.requireID(),
                expires: Vault.Expires(day: 31, month: 12, year: 2026),
            )

            try await app.testing().test(
                .POST,
                "vaults",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .internalServerError)
                },
            )
        }
    }

    @Test
    func `Create rolls back the vault row when the secret write fails`() async throws {
        try await withApp { app in
            stubTapis(on: app, status: .serviceUnavailable)
            let account = try await makeAccount(on: app.db)
            let payload = Vault.Create(
                token: "ghp_example",
                accountID: try account.requireID(),
                expires: Vault.Expires(day: 31, month: 12, year: 2026),
            )

            try await app.testing().test(
                .POST,
                "vaults",
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
        try await withApp { app in
            let first = try await makeAccount(on: app.db, name: "alpha")
            let second = try await makeAccount(on: app.db, name: "beta", platform: .npm)
            _ = try await makeVault(on: app.db, accountID: try first.requireID(), name: "alpha-token")
            _ = try await makeVault(on: app.db, accountID: try second.requireID(), name: "beta-token")

            try await app.testing().test(
                .GET,
                "vaults",
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
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let vault = try await makeVault(on: app.db, accountID: try account.requireID())
            let vaultID = try vault.requireID()

            try await app.testing().test(
                .GET,
                "vaults/\(vaultID)",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let returned = try res.content.decode(Vault.Public.self)
                    #expect(returned.id == vaultID)
                },
            )
        }
    }

    @Test
    func `Update sets the expiration date`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let vault = try await makeVault(on: app.db, accountID: try account.requireID())

            let update = Vault.Update(token: "ghp_rotated", expires: Vault.Expires(day: 31, month: 12, year: 2026))
            try await app.testing().test(
                .PATCH,
                "vaults/\(vault.requireID())",
                beforeRequest: { req in try req.content.encode(update) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let model = try #require(await Vault.find(vault.requireID(), on: app.db))
                    let expiresAt = try #require(model.expiresAt)
                    let components = Calendar(identifier: .gregorian)
                        .dateComponents([.year, .month, .day], from: expiresAt)
                    #expect(components.year == 2026)
                    #expect(components.month == 12)
                    #expect(components.day == 31)
                },
            )
        }
    }

    @Test
    func `Delete vault`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let vault = try await makeVault(on: app.db, accountID: try account.requireID())

            try await app.testing().test(
                .DELETE,
                "vaults/\(vault.requireID())",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                    let model = try await Vault.find(vault.id, on: app.db)
                    #expect(model == nil)
                },
            )
        }
    }
}
