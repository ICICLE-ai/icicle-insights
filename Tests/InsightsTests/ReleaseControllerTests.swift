import Fluent
import Foundation
@testable import Insights
import Testing
import VaporTesting

@Suite("Release Controller", .serialized)
struct ReleaseControllerTests {
    @Test
    func `Create derives releasedAt from month and year`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let payload = Release.Create(version: "1.0.0", month: 7, year: 2026, resourceID: try resource.requireID())

            try await app.testing().test(
                .POST,
                "releases",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .created)
                    let returned = try res.content.decode(Release.Public.self)
                    #expect(returned.version == "1.0.0")
                    let releasedAt = try #require(returned.releasedAt)
                    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: releasedAt)
                    #expect(components.year == 2026)
                    #expect(components.month == 7)
                },
            )
        }
    }

    @Test
    func `Create rejects a blank version`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let payload = Release.Create(version: "  ", month: 7, year: 2026, resourceID: try resource.requireID())

            try await app.testing().test(
                .POST,
                "releases",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Release.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Create rejects an out of range month`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let payload = Release.Create(version: "1.0.0", month: 99, year: 2026, resourceID: try resource.requireID())

            try await app.testing().test(
                .POST,
                "releases",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Release.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Create rejects an out of range year`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let payload = Release.Create(version: "1.0.0", month: 7, year: 0, resourceID: try resource.requireID())

            try await app.testing().test(
                .POST,
                "releases",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Release.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Create with missing resource is a bad request`() async throws {
        try await withApp { app in
            let payload = Release.Create(version: "1.0.0", month: 7, year: 2026, resourceID: UUID())

            try await app.testing().test(
                .POST,
                "releases",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Release.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Index returns all releases`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let resourceID = try resource.requireID()
            _ = try await makeRelease(on: app.db, resourceID: resourceID, version: "1.0.0")
            _ = try await makeRelease(on: app.db, resourceID: resourceID, version: "1.1.0")

            try await app.testing().test(
                .GET,
                "releases",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let versions = try res.content.decode([Release.Public].self).compactMap(\.version).sorted()
                    #expect(versions == ["1.0.0", "1.1.0"])
                },
            )
        }
    }

    @Test
    func `Show release by ID`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let release = try await makeRelease(on: app.db, resourceID: try resource.requireID())
            let releaseID = try release.requireID()

            try await app.testing().test(
                .GET,
                "releases/\(releaseID)",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let returned = try res.content.decode(Release.Public.self)
                    #expect(returned.id == releaseID)
                },
            )
        }
    }

    @Test
    func `Delete release`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let release = try await makeRelease(on: app.db, resourceID: try resource.requireID())

            try await app.testing().test(
                .DELETE,
                "releases/\(release.requireID())",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                    let model = try await Release.find(release.id, on: app.db)
                    #expect(model == nil)
                },
            )
        }
    }
}
