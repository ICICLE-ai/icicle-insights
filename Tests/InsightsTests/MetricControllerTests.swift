import Fluent
@testable import Insights
import Testing
import VaporTesting

@Suite("Metric Controller", .serialized)
struct MetricControllerTests {
    @Test
    func `Create metric`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let payload = Metric.Create(reading: 100, type: .stars, resourceID: try resource.requireID())

            try await app.testing().test(
                .POST,
                "metrics",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .created)
                    let returned = try res.content.decode(Metric.Public.self)
                    #expect(returned.reading == 100)
                    #expect(returned.type == .stars)
                    #expect(returned.resourceID == resource.id)
                },
            )
        }
    }

    @Test
    func `Create rejects a negative reading`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let payload = Metric.Create(reading: -1, type: .stars, resourceID: try resource.requireID())

            try await app.testing().test(
                .POST,
                "metrics",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Metric.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Create with missing resource is a bad request`() async throws {
        try await withApp { app in
            let payload = Metric.Create(reading: 1, type: .stars, resourceID: UUID())

            try await app.testing().test(
                .POST,
                "metrics",
                beforeRequest: { req in try req.content.encode(payload) },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let count = try await Metric.query(on: app.db).count()
                    #expect(count == 0)
                },
            )
        }
    }

    @Test
    func `Index returns readings oldest to newest`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let resourceID = try resource.requireID()
            for reading in [1.0, 2.0, 3.0] {
                _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: reading)
            }

            try await app.testing().test(
                .GET,
                "metrics",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let readings = try res.content.decode([Metric.Public].self).compactMap(\.reading)
                    #expect(readings == [1, 2, 3])
                },
            )
        }
    }

    @Test
    func `Index filters by type`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let resourceID = try resource.requireID()
            _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: 10, type: .stars)
            _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: 20, type: .stars)
            _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: 5, type: .downloads)

            try await app.testing().test(
                .GET,
                "metrics?type=stars",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let returned = try res.content.decode([Metric.Public].self)
                    #expect(returned.count == 2)
                    #expect(returned.allSatisfy { $0.type == .stars })
                },
            )
        }
    }

    @Test
    func `Index filters by resourceID`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let accountID = try account.requireID()
            let first = try await makeResource(on: app.db, accountID: accountID, name: "insights", type: .model)
            let second = try await makeResource(on: app.db, accountID: accountID, name: "insights-cli", type: .package)
            let firstID = try first.requireID()
            _ = try await makeMetric(on: app.db, resourceID: firstID, reading: 1)
            _ = try await makeMetric(on: app.db, resourceID: firstID, reading: 2)
            _ = try await makeMetric(on: app.db, resourceID: try second.requireID(), reading: 3)

            try await app.testing().test(
                .GET,
                "metrics?resourceID=\(firstID)",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let returned = try res.content.decode([Metric.Public].self)
                    #expect(returned.count == 2)
                    #expect(returned.allSatisfy { $0.resourceID == firstID })
                },
            )
        }
    }

    @Test
    func `Index honors limit and returns the most recent rows`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let resourceID = try resource.requireID()
            for reading in [1.0, 2.0, 3.0, 4.0, 5.0] {
                _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: reading)
            }

            try await app.testing().test(
                .GET,
                "metrics?limit=3",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    // Most recent 3 (4,5 newest) returned oldest→newest.
                    let readings = try res.content.decode([Metric.Public].self).compactMap(\.reading)
                    #expect(readings == [3, 4, 5])
                },
            )
        }
    }

    // The `-> Void` is load-bearing: VaporTesting exports a generic `withApp<T>` that skips
    // `configure`, and a single-expression closure returns the tester, which would select that
    // overload and leave the app with no routes.
    @Test(arguments: ["-1", "0", "1001"])
    func `Index rejects an out of range limit`(limit: String) async throws {
        try await withApp { app -> Void in
            try await app.testing().test(
                .GET,
                "metrics?limit=\(limit)",
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                },
            )
        }
    }

    @Test
    func `Show metric by ID`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let metric = try await makeMetric(on: app.db, resourceID: try resource.requireID())
            let metricID = try metric.requireID()

            try await app.testing().test(
                .GET,
                "metrics/\(metricID)",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let returned = try res.content.decode(Metric.Public.self)
                    #expect(returned.id == metricID)
                },
            )
        }
    }

    @Test
    func `Delete metric`() async throws {
        try await withApp { app in
            let account = try await makeAccount(on: app.db)
            let resource = try await makeResource(on: app.db, accountID: try account.requireID())
            let metric = try await makeMetric(on: app.db, resourceID: try resource.requireID())

            try await app.testing().test(
                .DELETE,
                "metrics/\(metric.requireID())",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                    let model = try await Metric.find(metric.id, on: app.db)
                    #expect(model == nil)
                },
            )
        }
    }
}
