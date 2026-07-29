import Fluent
@testable import Insights
import Testing
import VaporTesting

@Suite("Account Controller", .serialized)
struct AccountControllerTests {
    @Test
    func `Create lowercases the name`() async throws {
        try await withApp { app in
            let payload = Account.Create(name: "OctoCat", platform: .github)
            try await app.testing().test(
                .POST,
                "accounts",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .created)
                    let returned = try res.content.decode(Account.Public.self)
                    #expect(returned.name == "octocat")
                    let stored = try await Account.query(on: app.db).all()
                    #expect(stored.map(\.name) == ["octocat"])
                },
            )
        }
    }

    @Test
    func `Create supports GitHub Container Registry accounts`() async throws {
        try await withApp { app in
            let payload = Account.Create(name: "icicle-ai", platform: .ghcr)
            try await app.testing().test(
                .POST,
                "accounts",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .created)
                    let returned = try res.content.decode(Account.Public.self)
                    #expect(returned.name == "icicle-ai")
                    #expect(returned.platform == .ghcr)
                },
            )
        }
    }

    @Test
    func `Create rejects a blank name`() async throws {
        try await withApp { app in
            let payload = Account.Create(name: "   ", platform: .github)
            try await app.testing().test(
                .POST,
                "accounts",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Account.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Create rejects a duplicate name on the same platform`() async throws {
        try await withApp { app in
            _ = try await makeAccount(on: app.db, name: "octocat", platform: .github)

            let payload = Account.Create(name: "OctoCat", platform: .github)
            try await app.testing().test(
                .POST,
                "accounts",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .conflict)
                    let count = try await Account.query(on: app.db).count()
                    #expect(count == 1)
                },
            )
        }
    }

    @Test
    func `Index returns all accounts`() async throws {
        try await withApp { app in
            _ = try await makeAccount(on: app.db, name: "alpha")
            _ = try await makeAccount(on: app.db, name: "beta", platform: .npm)

            try await app.testing().test(
                .GET,
                "accounts",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let names = try res.content.decode([Account.Public].self).compactMap(\.name).sorted()
                    #expect(names == ["alpha", "beta"])
                },
            )
        }
    }

    @Test
    func `Show includes resources and vault`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let accountID = try account.requireID()
            _ = try await makeResource(on: app.db, accountID: accountID)
            _ = try await makeVault(on: app.db, accountID: accountID)

            try await app.testing().test(
                .GET,
                "accounts/\(accountID)",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let returned = try res.content.decode(Account.Public.self)
                    #expect(returned.id == accountID)
                    #expect(returned.resources?.count == 1)
                    #expect(returned.vault != nil)
                },
            )
        }
    }

    @Test
    func `Update followers`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db, followers: 0)

            let update = Account.Update(followers: 42)
            try await app.testing().test(
                .PATCH,
                "accounts/\(account.requireID())",
                beforeRequest: { req in try req.content.encode(update) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let model = try #require(await Account.find(account.requireID(), on: app.db))
                    #expect(model.followers == 42)
                },
            )
        }
    }

    @Test
    func `Update rejects negative followers`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db, followers: 10)

            let update = Account.Update(followers: -1)
            try await app.testing().test(
                .PATCH,
                "accounts/\(account.requireID())",
                beforeRequest: { req in try req.content.encode(update) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let model = try #require(await Account.find(account.requireID(), on: app.db))
                    #expect(model.followers == 10)
                },
            )
        }
    }

    @Test
    func `Delete account`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)

            try await app.testing().test(
                .DELETE,
                "accounts/\(account.requireID())",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                    let model = try await Account.find(account.id, on: app.db)
                    #expect(model == nil)
                },
            )
        }
    }
}
