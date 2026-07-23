import Fluent
import Foundation
import SQLKit

/// Development-only sample data so the dashboard has a rich, realistic dataset to demo.
/// Registered only in `.development` (see `configure.swift`), so it targets the `dev`
/// database and never `test`. Covers every Platform, ResourceType, and MetricType.
struct SeedData: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    // ~5 months of daily readings per series.
    private static let points = 150
    private static let dayInterval: TimeInterval = 24 * 3600

    // MARK: Seed catalog

    private struct ResourceSpec {
        let name: String
        let type: ResourceType
        let popularity: Double // scales the reading magnitudes
        let releases: [String]
    }

    private struct AccountSpec {
        let name: String
        let platform: Platform
        let followers: Int
        let resources: [ResourceSpec]
    }

    private static let catalog: [AccountSpec] = [
        AccountSpec(name: "vapor", platform: .github, followers: 24_100, resources: [
            ResourceSpec(name: "vapor", type: .service, popularity: 2.2, releases: ["4.100.0", "4.110.0", "4.121.0"]),
            ResourceSpec(name: "fluent", type: .package, popularity: 1.1, releases: ["4.9.0", "4.12.0", "4.13.0"]),
            ResourceSpec(name: "leaf", type: .package, popularity: 0.8, releases: ["4.3.0", "4.4.0", "4.5.0"]),
        ]),
        AccountSpec(name: "pointfreeco", platform: .github, followers: 18_900, resources: [
            ResourceSpec(name: "composable-architecture", type: .package, popularity: 1.7, releases: ["1.10.0", "1.15.0", "1.17.0"]),
            ResourceSpec(name: "snapshot-testing", type: .package, popularity: 0.7, releases: ["1.16.0", "1.17.0"]),
        ]),
        AccountSpec(name: "apple", platform: .github, followers: 92_500, resources: [
            ResourceSpec(name: "swift", type: .service, popularity: 3.0, releases: ["5.10", "6.0", "6.1"]),
            ResourceSpec(name: "swift-nio", type: .package, popularity: 1.3, releases: ["2.68.0", "2.76.0"]),
        ]),
        AccountSpec(name: "octocat", platform: .github, followers: 12_480, resources: [
            ResourceSpec(name: "insights", type: .service, popularity: 1.4, releases: ["1.0.0", "1.1.0", "1.2.0", "2.0.0"]),
            ResourceSpec(name: "insights-cli", type: .package, popularity: 0.7, releases: ["0.9.0", "1.0.0", "1.1.0"]),
            ResourceSpec(name: "insights-banner", type: .image, popularity: 0.5, releases: ["1.0.0"]),
        ]),
        AccountSpec(name: "huggingface", platform: .huggingface, followers: 51_200, resources: [
            ResourceSpec(name: "transformers", type: .model, popularity: 3.0, releases: ["4.44", "4.46", "4.48"]),
            ResourceSpec(name: "datasets", type: .dataset, popularity: 1.5, releases: ["3.0", "3.1"]),
        ]),
        AccountSpec(name: "meta-llama", platform: .huggingface, followers: 40_300, resources: [
            ResourceSpec(name: "llama-3", type: .model, popularity: 2.4, releases: ["3.0", "3.1", "3.2"]),
        ]),
        AccountSpec(name: "google", platform: .huggingface, followers: 33_700, resources: [
            ResourceSpec(name: "gemma", type: .model, popularity: 1.8, releases: ["1.1", "2.0"]),
            ResourceSpec(name: "c4", type: .dataset, popularity: 0.9, releases: ["2024.1"]),
        ]),
        AccountSpec(name: "expressjs", platform: .npm, followers: 15_600, resources: [
            ResourceSpec(name: "express", type: .package, popularity: 2.6, releases: ["4.19.0", "4.21.0", "5.0.0"]),
        ]),
        AccountSpec(name: "vercel", platform: .npm, followers: 28_400, resources: [
            ResourceSpec(name: "next", type: .package, popularity: 2.9, releases: ["14.2.0", "15.0.0", "15.1.0"]),
            ResourceSpec(name: "swr", type: .package, popularity: 0.9, releases: ["2.2.0", "2.3.0"]),
        ]),
        AccountSpec(name: "scikit-learn", platform: .pypi, followers: 22_100, resources: [
            ResourceSpec(name: "scikit-learn", type: .package, popularity: 2.7, releases: ["1.4.0", "1.5.0", "1.6.0"]),
        ]),
        AccountSpec(name: "pandas-dev", platform: .pypi, followers: 26_800, resources: [
            ResourceSpec(name: "pandas", type: .package, popularity: 3.1, releases: ["2.1.0", "2.2.0", "2.3.0"]),
        ]),
    ]

    // Metric types are chosen by resource type so the mix reads realistically; together
    // they cover all eight MetricType cases.
    private static func metricTypes(for type: ResourceType) -> [MetricType] {
        switch type {
        case .service: [.stars, .forks, .views, .clones, .pulls, .subscribers]
        case .package: [.stars, .forks, .downloads]
        case .model: [.likes, .downloads]
        case .dataset: [.likes, .downloads]
        case .image: [.views]
        }
    }

    private static func baseline(for type: MetricType) -> Double {
        switch type {
        case .downloads: 6_000
        case .views: 1_400
        case .likes: 380
        case .stars: 450
        case .clones: 200
        case .subscribers: 160
        case .forks: 70
        case .pulls: 28
        }
    }

    // MARK: Migration

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw UnsupportedDatabase() // Postgres only; never reached in practice.
        }

        let now = Date()
        let start = now.addingTimeInterval(-Double(Self.points - 1) * Self.dayInterval)

        for spec in Self.catalog {
            let account = Account(name: spec.name, platform: spec.platform, followers: spec.followers)
            try await account.create(on: database)
            let accountID = try account.requireID()

            let vault = Vault(
                accountID: accountID,
                name: "\(spec.name)-token",
                expiresAt: now.addingTimeInterval(90 * Self.dayInterval),
            )
            try await vault.create(on: database)

            for resourceSpec in spec.resources {
                let resource = Resource(name: resourceSpec.name, type: resourceSpec.type, accountID: accountID)
                try await resource.create(on: database)
                let resourceID = try resource.requireID()

                for type in Self.metricTypes(for: resourceSpec.type) {
                    let base = Self.baseline(for: type) * resourceSpec.popularity
                    try await seedSeries(
                        on: sql,
                        resourceID: resourceID,
                        type: type,
                        base: base,
                        slope: base * Double.random(in: 0.008 ... 0.025),
                        amplitude: base * Double.random(in: 0.05 ... 0.12),
                        start: start,
                    )
                }

                let count = resourceSpec.releases.count
                let releases = resourceSpec.releases.enumerated().map { index, version in
                    Release(
                        resourceID: resourceID,
                        version: version,
                        releasedAt: start.addingTimeInterval(Double(index + 1) / Double(count + 1)
                            * Double(Self.points - 1) * Self.dayInterval),
                    )
                }
                try await releases.create(on: database)
            }
        }
    }

    func revert(on database: any Database) async throws {
        // Force-delete each seeded account; DB-level ON DELETE CASCADE removes its vault,
        // resources, and (through resources) metrics and releases.
        for spec in Self.catalog {
            let accounts = try await Account.query(on: database)
                .filter(\.$name == spec.name)
                .filter(\.$platform == spec.platform)
                .all()
            for account in accounts {
                try await account.delete(force: true, on: database)
            }
        }
    }

    /// Bulk-inserts one metric time series with historical `recorded_at` values. A raw
    /// multi-row insert both sidesteps the `@Timestamp(on: .create)` "stamp now" behaviour
    /// and is far faster than one round trip per row.
    private func seedSeries(
        on sql: any SQLDatabase,
        resourceID: Resource.IDValue,
        type: MetricType,
        base: Double,
        slope: Double,
        amplitude: Double,
        start: Date,
    ) async throws {
        var query = SQLQueryString("INSERT INTO metrics (id, resource_id, reading, type, recorded_at) VALUES ")
        for i in 0 ..< Self.points {
            let weekly = amplitude * sin(2 * .pi * Double(i) / 7)
            let noise = Double.random(in: -amplitude / 2 ... amplitude / 2)
            let reading = max(0, base + slope * Double(i) + weekly + noise).rounded()
            let recordedAt = start.addingTimeInterval(Double(i) * Self.dayInterval)

            if i > 0 { query.appendLiteral(", ") }
            query.appendLiteral("(")
            query.appendInterpolation(bind: UUID())
            query.appendLiteral(", ")
            query.appendInterpolation(bind: resourceID)
            query.appendLiteral(", ")
            query.appendInterpolation(bind: reading)
            query.appendLiteral(", ")
            query.appendInterpolation(bind: type.rawValue)
            query.appendLiteral("::metric_type, ")
            query.appendInterpolation(bind: recordedAt)
            query.appendLiteral(")")
        }
        try await sql.raw(query).run()
    }
}
