import Fluent
import Foundation
import SQLKit

/// The real ICICLE GitHub, GHCR, npm, and Hugging Face datasets captured in July 2026 and
/// previously applied by hand through `Kulala/migrations/*.http`. Registered only in
/// `.development` (see `configure.swift`), so it targets the `dev` database and never `test`.
///
/// This is a point-in-time snapshot: every metric is a single reading, so the dashboard's trend
/// charts render one point per series until a later sweep is recorded. This is the only seed
/// data in the project — every figure here is real, and nothing synthetic is seeded anywhere.
struct ICICLESnapshotJuly2026: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    private static let accountName = "icicle-ai"
    private static let platform = Platform.github
    private static let followers = 44

    /// The instant every reading was captured, taken from the source export's timestamp. All 109
    /// rows share it so the snapshot reads as one coherent sweep rather than a smear of instants.
    private static let snapshotDate = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 2026, month: 7, day: 24, hour: 16, minute: 17
    ).date!

    // MARK: Snapshot catalog

    private struct ReleaseSpec {
        let version: String
        let month: Int
        let year: Int

        init(_ version: String, month: Int, year: Int) {
            self.version = version
            self.month = month
            self.year = year
        }

        /// Releases are dated to month precision upstream, so they land on the 1st at 00:00 UTC.
        var releasedAt: Date {
            DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: year, month: month, day: 1
            ).date!
        }
    }

    private struct MetricSpec {
        let type: MetricType
        let reading: Double

        init(_ type: MetricType, _ reading: Double) {
            self.type = type
            self.reading = reading
        }
    }

    private struct RepositorySpec {
        let name: String
        let releases: [ReleaseSpec]
        let metrics: [MetricSpec]
    }

    private struct ResourceSpec {
        let name: String
        let type: ResourceType
        let metrics: [MetricSpec]

        init(_ name: String, type: ResourceType, metrics: [MetricSpec]) {
            self.name = name
            self.type = type
            self.metrics = metrics
        }
    }

    private struct AccountSpec {
        let platform: Platform
        let followers: Int
        let resources: [ResourceSpec]
    }

    /// Container, package, and Hugging Face exports captured alongside the GitHub repository snapshot.
    /// Zero-valued readings are intentionally omitted while their resources are retained.
    private static let additionalAccounts: [AccountSpec] = [
        AccountSpec(platform: .ghcr, followers: 0, resources: [
            ResourceSpec("fass-back", type: .container, metrics: [.init(.pullsAllTime, 346)]),
            ResourceSpec("fass-front", type: .container, metrics: [.init(.pullsAllTime, 344)]),
            ResourceSpec("store-closure-back", type: .container, metrics: [.init(.pullsAllTime, 261)]),
            ResourceSpec("insights", type: .container, metrics: [.init(.pullsAllTime, 243)]),
            ResourceSpec("store-closure-front", type: .container, metrics: [.init(.pullsAllTime, 224)]),
            ResourceSpec("catalogfrontend", type: .container, metrics: [.init(.pullsAllTime, 192)]),
            ResourceSpec("food-security-sandbox-frontend", type: .container, metrics: [.init(.pullsAllTime, 185)]),
            ResourceSpec("foodshed-conv-ai", type: .container, metrics: [.init(.pullsAllTime, 179)]),
            ResourceSpec("megadetector-server", type: .container, metrics: [.init(.pullsAllTime, 164)]),
            ResourceSpec("smart-compiler", type: .container, metrics: [.init(.pullsAllTime, 164)]),
            ResourceSpec("harp-framework-ci", type: .container, metrics: [.init(.pullsAllTime, 143)]),
            ResourceSpec("harp-app-eulernumber-ci", type: .container, metrics: [.init(.pullsAllTime, 140)]),
            ResourceSpec("gnnfoodflow-portal", type: .container, metrics: [.init(.pullsAllTime, 136)]),
            ResourceSpec("harp-framework-local", type: .container, metrics: [.init(.pullsAllTime, 131)]),
            ResourceSpec("harp-app-eulernumber-local", type: .container, metrics: [.init(.pullsAllTime, 130)]),
            ResourceSpec("array-morph", type: .container, metrics: [.init(.pullsAllTime, 130)]),
            ResourceSpec("food-security-sandbox-backend", type: .container, metrics: [.init(.pullsAllTime, 124)]),
            ResourceSpec("catalogbackend", type: .container, metrics: [.init(.pullsAllTime, 124)]),
            ResourceSpec("plug-n-play-megadetector-v6b", type: .container, metrics: [.init(.pullsAllTime, 113)]),
            ResourceSpec("umami", type: .container, metrics: [.init(.pullsAllTime, 99)]),
            ResourceSpec("food-security-sandbox-sandbox", type: .container, metrics: [.init(.pullsAllTime, 97)]),
            ResourceSpec("food-security-sandbox-param", type: .container, metrics: [.init(.pullsAllTime, 96)]),
            ResourceSpec("icicle-ai-vector-service", type: .container, metrics: [.init(.pullsAllTime, 92)]),
            ResourceSpec("icicle-ai-embed-service", type: .container, metrics: [.init(.pullsAllTime, 83)]),
            ResourceSpec("harvest-preprocessing", type: .container, metrics: [.init(.pullsAllTime, 78)]),
            ResourceSpec("store-closure-abm", type: .container, metrics: [.init(.pullsAllTime, 68)]),
            ResourceSpec("smart-labeler-frontend", type: .container, metrics: [.init(.pullsAllTime, 60)]),
            ResourceSpec("playgrounds-demo", type: .container, metrics: [.init(.pullsAllTime, 47)]),
            ResourceSpec("icicle-playgrounds", type: .container, metrics: [.init(.pullsAllTime, 43)]),
            ResourceSpec("opencv-image-playground", type: .container, metrics: [.init(.pullsAllTime, 38)]),
            ResourceSpec("mlhub-mcp", type: .container, metrics: [.init(.pullsAllTime, 31)]),
            ResourceSpec("bioclip-api", type: .container, metrics: [.init(.pullsAllTime, 31)]),
            ResourceSpec("sam3-inference-service", type: .container, metrics: [.init(.pullsAllTime, 30)]),
            ResourceSpec("harvest-inference", type: .container, metrics: [.init(.pullsAllTime, 28)]),
            ResourceSpec("icicle-chatbook", type: .container, metrics: [.init(.pullsAllTime, 27)]),
            ResourceSpec("smart-labeler-backend", type: .container, metrics: [.init(.pullsAllTime, 23)]),
            ResourceSpec("hpc-mcp-server", type: .container, metrics: [.init(.pullsAllTime, 23)]),
            ResourceSpec("opencv-image-playground-bridge", type: .container, metrics: [.init(.pullsAllTime, 13)]),
            ResourceSpec("hpc-mcp-server-cpu", type: .container, metrics: [.init(.pullsAllTime, 8)]),
            ResourceSpec("rag-chatbot-harvest-websocket-service", type: .container, metrics: [.init(.pullsAllTime, 6)]),
            ResourceSpec("rag-chatbot-harvest-api-service", type: .container, metrics: [.init(.pullsAllTime, 6)]),
            ResourceSpec("rag-chatbot-harvest-model-service", type: .container, metrics: [.init(.pullsAllTime, 6)]),
            ResourceSpec("gnnfoodflowportal", type: .container, metrics: []),
            ResourceSpec("fass-api", type: .container, metrics: []),
            ResourceSpec("isawfrontend", type: .container, metrics: []),
        ]),
        AccountSpec(platform: .npm, followers: 0, resources: [
            ResourceSpec("opencv-image-playground", type: .package, metrics: []),
            ResourceSpec("opencv-image-playground-core", type: .package, metrics: []),
            ResourceSpec("annotation-details", type: .package, metrics: []),
            ResourceSpec("image-annotation-canvas", type: .package, metrics: []),
            ResourceSpec("image-annotator", type: .package, metrics: []),
            ResourceSpec("tapis-file-explorer", type: .package, metrics: []),
            ResourceSpec("patra-model-selector", type: .package, metrics: []),
        ]),
        // These came from Hugging Face's `downloadsAllTime` field, so they are cumulative
        // totals rather than the sliding 30-day `downloads` figure, and are typed accordingly.
        AccountSpec(platform: .huggingface, followers: 20, resources: [
            ResourceSpec("foodflow_gnn_model", type: .model, metrics: []),
            ResourceSpec("yolov9-animals-ae-data", type: .model, metrics: [.init(.downloadsAllTime, 151)]),
            ResourceSpec("can_benchmark", type: .dataset, metrics: [.init(.downloadsAllTime, 202)]),
            ResourceSpec("organization-sic-code_smart-foodsheds", type: .dataset, metrics: [.init(.downloadsAllTime, 209)]),
            ResourceSpec("resourceestimation_hlogencnn", type: .dataset, metrics: [.init(.downloadsAllTime, 507)]),
        ]),
        // Named for the PyPI project, not the ICICLE-Playgrounds repository that builds it:
        // the registry is authoritative for its own artifact. Its 0.1.5.5 release is already
        // recorded on that repository, so it is not repeated here.
        AccountSpec(platform: .pypi, followers: 0, resources: [
            ResourceSpec("icicle-playgrounds", type: .package, metrics: []),
        ]),
    ]


    private static let repositories: [RepositorySpec] = [
        RepositorySpec(
            name: "adae_model",
            releases: [.init("1.0.0", month: 12, year: 2024)],
            metrics: [.init(.clonesAllTime, 14)]
        ),
        RepositorySpec(
            name: "ag_routing_data_generator",
            releases: [.init("0.1.0", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 32), .init(.starsAllTime, 1), .init(.viewsAllTime, 31)]
        ),
        RepositorySpec(
            name: "ArrayMorph",
            releases: [.init("1.0", month: 9, year: 2024), .init("1.1", month: 5, year: 2025), .init("1.2", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 1108), .init(.forksAllTime, 1), .init(.subscribersAllTime, 1), .init(.viewsAllTime, 479)]
        ),
        RepositorySpec(
            name: "AUTOLYCUS",
            releases: [.init("1.0", month: 9, year: 2024)],
            metrics: [.init(.clonesAllTime, 21), .init(.subscribersAllTime, 1)]
        ),
        RepositorySpec(
            name: "AutoSDT",
            releases: [.init("1.0.0", month: 3, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "Camera_Trap",
            releases: [.init("1.0.0", month: 10, year: 2025)],
            metrics: [.init(.clonesAllTime, 31), .init(.forksAllTime, 1), .init(.starsAllTime, 5), .init(.subscribersAllTime, 1), .init(.viewsAllTime, 3)]
        ),
        RepositorySpec(
            name: "CAN-Benchmark",
            releases: [.init("1.0.0", month: 10, year: 2025)],
            metrics: [.init(.clonesAllTime, 25), .init(.starsAllTime, 1), .init(.viewsAllTime, 8)]
        ),
        RepositorySpec(
            name: "catalog_mcp",
            releases: [.init("1.0.0", month: 3, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "CI-Components-Catalog",
            releases: [.init("0.1.0", month: 4, year: 2023), .init("0.2.0", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 89), .init(.forksAllTime, 3), .init(.starsAllTime, 1), .init(.subscribersAllTime, 4), .init(.viewsAllTime, 58)]
        ),
        RepositorySpec(
            name: "ct-controller",
            releases: [.init("0.1", month: 9, year: 2024), .init("0.2", month: 5, year: 2025), .init("0.3", month: 10, year: 2025)],
            metrics: [.init(.clonesAllTime, 203), .init(.subscribersAllTime, 2), .init(.viewsAllTime, 325)]
        ),
        RepositorySpec(
            name: "cyberinfrastructure-knowledge-network",
            releases: [.init("0.1.0", month: 12, year: 2024), .init("0.2.0", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 10), .init(.viewsAllTime, 3)]
        ),
        RepositorySpec(
            name: "distributed_training_estimator_of_LLM",
            releases: [.init("0.0.1", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 101), .init(.forksAllTime, 3), .init(.starsAllTime, 1), .init(.viewsAllTime, 123)]
        ),
        RepositorySpec(
            name: "faf-api-icicle",
            releases: [.init("0.1.0", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 14), .init(.viewsAllTime, 3)]
        ),
        RepositorySpec(
            name: "faf-frontend-icicle",
            releases: [.init("0.1.0", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 18), .init(.viewsAllTime, 1)]
        ),
        RepositorySpec(
            name: "FASS-Frontend",
            releases: [.init("0.2", month: 8, year: 2025), .init("0.3", month: 10, year: 2025), .init("0.4", month: 12, year: 2025)],
            metrics: []
        ),
        RepositorySpec(
            name: "fastkg-icicle",
            releases: [.init("0.1.0", month: 4, year: 2024)],
            metrics: [.init(.clonesAllTime, 9), .init(.viewsAllTime, 7)]
        ),
        RepositorySpec(
            name: "flaskauthn",
            releases: [.init("1.0", month: 10, year: 2023)],
            metrics: [.init(.clonesAllTime, 20), .init(.subscribersAllTime, 3), .init(.viewsAllTime, 1)]
        ),
        RepositorySpec(
            name: "Food-Access-Model",
            releases: [.init("0.1", month: 12, year: 2024), .init("0.2", month: 8, year: 2025), .init("0.3", month: 10, year: 2025), .init("0.4", month: 12, year: 2025)],
            metrics: [.init(.clonesAllTime, 1696), .init(.forksAllTime, 2), .init(.starsAllTime, 3), .init(.subscribersAllTime, 3), .init(.viewsAllTime, 3741)]
        ),
        RepositorySpec(
            name: "food-security-sandbox",
            releases: [.init("1.0.0", month: 8, year: 2025)],
            metrics: [.init(.clonesAllTime, 314), .init(.forksAllTime, 1), .init(.subscribersAllTime, 1), .init(.viewsAllTime, 24)]
        ),
        RepositorySpec(
            name: "FoodWasteWhiz",
            releases: [.init("0.1", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 30)]
        ),
        RepositorySpec(
            name: "forte-api",
            releases: [.init("0.1.0", month: 5, year: 2025)],
            metrics: [.init(.clonesAllTime, 14), .init(.viewsAllTime, 22)]
        ),
        RepositorySpec(
            name: "GNNFoodFlowPortal",
            releases: [.init("1.0.0", month: 8, year: 2025), .init("1.1.0", month: 10, year: 2025), .init("1.2.0", month: 5, year: 2026)],
            metrics: [.init(.clonesAllTime, 110), .init(.viewsAllTime, 38)]
        ),
        RepositorySpec(
            name: "harp",
            releases: [.init("1.0.0", month: 4, year: 2023), .init("2.0.0", month: 10, year: 2023)],
            metrics: [.init(.clonesAllTime, 26), .init(.viewsAllTime, 127)]
        ),
        RepositorySpec(
            name: "harvest",
            releases: [.init("0.9", month: 9, year: 2024), .init("1.0", month: 7, year: 2025), .init("1.1", month: 8, year: 2025), .init("1.2", month: 8, year: 2025), .init("1.3", month: 12, year: 2025), .init("1.4", month: 3, year: 2026)],
            metrics: [.init(.clonesAllTime, 380), .init(.viewsAllTime, 98)]
        ),
        RepositorySpec(
            name: "hello_icicle_auth_clients",
            releases: [.init("0.0.1", month: 4, year: 2023), .init("0.0.10", month: 6, year: 2023), .init("0.1.4", month: 6, year: 2023), .init("1.0.11", month: 10, year: 2023), .init("0.8.0", month: 10, year: 2023)],
            metrics: [.init(.clonesAllTime, 12), .init(.starsAllTime, 1)]
        ),
        RepositorySpec(
            name: "icicle-ai-embed-service",
            releases: [.init("0.1.0", month: 5, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "icicle-ai-vector-service",
            releases: [.init("0.1.0", month: 5, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "icicle-chatbook",
            releases: [.init("0.1.0", month: 5, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "ICICLE-Playgrounds",
            releases: [.init("0.1.5.5", month: 8, year: 2025)],
            metrics: [.init(.clonesAllTime, 29), .init(.viewsAllTime, 38)]
        ),
        RepositorySpec(
            name: "ICICLE_Foodshed_Parser",
            releases: [.init("0.1", month: 6, year: 2023)],
            metrics: [.init(.clonesAllTime, 26), .init(.viewsAllTime, 3)]
        ),
        RepositorySpec(
            name: "intelligent-edge-management-service",
            releases: [.init("0.1.0", month: 7, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "isplib",
            releases: [.init("1.0", month: 4, year: 2023)],
            metrics: [.init(.clonesAllTime, 24), .init(.viewsAllTime, 27)]
        ),
        RepositorySpec(
            name: "mlfieldplanner",
            releases: [.init("0.1.0", month: 12, year: 2025)],
            metrics: [.init(.clonesAllTime, 32), .init(.viewsAllTime, 9)]
        ),
        RepositorySpec(
            name: "opencv-image-playground",
            releases: [.init("0.1.0", month: 7, year: 2026)],
            metrics: []
        ),
        RepositorySpec(
            name: "OpenPass",
            releases: [.init("1.0.0", month: 9, year: 2024), .init("2.0.0", month: 8, year: 2025)],
            metrics: [.init(.clonesAllTime, 47), .init(.forksAllTime, 1), .init(.viewsAllTime, 109)]
        ),
        RepositorySpec(
            name: "organization-sic-classifier-for-smart-foodsheds",
            releases: [.init("0.0.1", month: 7, year: 2025)],
            metrics: [.init(.clonesAllTime, 24), .init(.viewsAllTime, 75)]
        ),
        RepositorySpec(
            name: "PEFT_Vision",
            releases: [.init("0.1", month: 5, year: 2025)],
            metrics: [.init(.clonesAllTime, 28), .init(.subscribersAllTime, 2), .init(.viewsAllTime, 11)]
        ),
        RepositorySpec(
            name: "ppod_ca",
            releases: [.init("23.06", month: 6, year: 2023)],
            metrics: [.init(.clonesAllTime, 13)]
        ),
        RepositorySpec(
            name: "ppod_core",
            releases: [.init("0.5.0", month: 6, year: 2024)],
            metrics: [.init(.clonesAllTime, 17)]
        ),
        RepositorySpec(
            name: "ProfilingCompiler",
            releases: [.init("1.0", month: 9, year: 2024)],
            metrics: [.init(.clonesAllTime, 23), .init(.subscribersAllTime, 1), .init(.viewsAllTime, 3)]
        ),
        RepositorySpec(
            name: "Region2vec",
            releases: [.init("1.0", month: 6, year: 2023)],
            metrics: [.init(.clonesAllTime, 16), .init(.starsAllTime, 1)]
        ),
        RepositorySpec(
            name: "ScienceAgent",
            releases: [.init("1.0", month: 12, year: 2024)],
            metrics: []
        ),
        RepositorySpec(
            name: "ScienceAgentInterface",
            releases: [.init("1.0", month: 12, year: 2024), .init("2.0", month: 7, year: 2025), .init("2.1", month: 10, year: 2025)],
            metrics: [.init(.clonesAllTime, 24), .init(.viewsAllTime, 13)]
        ),
        RepositorySpec(
            name: "SMART-COMPILER",
            releases: [.init("1.0", month: 5, year: 2025), .init("2.0", month: 8, year: 2025)],
            metrics: [.init(.clonesAllTime, 38), .init(.forksAllTime, 1), .init(.subscribersAllTime, 3), .init(.viewsAllTime, 20)]
        ),
        RepositorySpec(
            name: "Smartfield-Backpack",
            releases: [.init("1.0.0", month: 12, year: 2025)],
            metrics: [.init(.clonesAllTime, 157), .init(.viewsAllTime, 39)]
        ),
        RepositorySpec(
            name: "softwarepilot",
            releases: [.init("1.2.5", month: 4, year: 2023)],
            metrics: [.init(.clonesAllTime, 14)]
        ),
        RepositorySpec(
            name: "species-classification-multimodal-context",
            releases: [.init("0.1.0", month: 6, year: 2023)],
            metrics: [.init(.clonesAllTime, 16), .init(.starsAllTime, 1)]
        ),
        RepositorySpec(
            name: "speech-server",
            releases: [.init("0.1", month: 9, year: 2024), .init("0.2", month: 12, year: 2024)],
            metrics: [.init(.clonesAllTime, 27), .init(.subscribersAllTime, 2), .init(.viewsAllTime, 1)]
        ),
        RepositorySpec(
            name: "Store_Closure_Website",
            releases: [.init("0.1", month: 6, year: 2023)],
            metrics: [.init(.clonesAllTime, 27), .init(.starsAllTime, 1)]
        ),
        RepositorySpec(
            name: "tapisui-extension-icicle",
            releases: [.init("0.1.0", month: 5, year: 2025)],
            metrics: [.init(.clonesAllTime, 30), .init(.subscribersAllTime, 1), .init(.viewsAllTime, 9)]
        ),
        RepositorySpec(
            name: "uas-orchestration-engine",
            releases: [.init("0.1", month: 12, year: 2025)],
            metrics: [.init(.clonesAllTime, 43), .init(.viewsAllTime, 100)]
        ),
        RepositorySpec(
            name: "VA_Dashboard_V3",
            releases: [.init("0.1", month: 4, year: 2023), .init("0.2", month: 6, year: 2023), .init("0.3", month: 10, year: 2023), .init("0.4", month: 9, year: 2024)],
            metrics: [.init(.clonesAllTime, 25), .init(.starsAllTime, 1), .init(.subscribersAllTime, 3), .init(.viewsAllTime, 11)]
        ),
    ]

    // MARK: Migration

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw UnsupportedDatabase() // Postgres only; never reached in practice.
        }

        let account = Account(name: Self.accountName, platform: Self.platform, followers: Self.followers)
        try await account.create(on: database)
        let accountID = try account.requireID()

        // Collected across every source so all readings go in as one statement, sharing the
        // snapshot timestamp. `Metric.recordedAt` is `@Timestamp(on: .create)`, which would
        // otherwise overwrite each row with "now" and scatter the sweep across many instants.
        var readings: [(resourceID: Resource.IDValue, spec: MetricSpec)] = []

        for repository in Self.repositories {
            let resource = Resource(name: repository.name, type: .repository, accountID: accountID)
            try await resource.create(on: database)
            let resourceID = try resource.requireID()

            // `Release.releasedAt` is `@Timestamp(on: .none)`, so the historical date is stored as given.
            let releases = repository.releases.map {
                Release(resourceID: resourceID, version: $0.version, releasedAt: $0.releasedAt)
            }
            try await releases.create(on: database)

            readings.append(contentsOf: repository.metrics.map { (resourceID, $0) })
        }

        for accountSpec in Self.additionalAccounts {
            let additionalAccount = Account(
                name: Self.accountName,
                platform: accountSpec.platform,
                followers: accountSpec.followers
            )
            try await additionalAccount.create(on: database)
            let additionalAccountID = try additionalAccount.requireID()

            for resourceSpec in accountSpec.resources {
                let resource = Resource(
                    name: resourceSpec.name,
                    type: resourceSpec.type,
                    accountID: additionalAccountID
                )
                try await resource.create(on: database)
                let resourceID = try resource.requireID()
                readings.append(contentsOf: resourceSpec.metrics.map { (resourceID, $0) })
            }
        }

        try await insertMetrics(on: sql, readings: readings)
    }

    func revert(on database: any Database) async throws {
        // Force-delete every account owned by this snapshot; DB-level ON DELETE CASCADE removes
        // their resources and, through those resources, their metrics and releases.
        let platforms = [Self.platform] + Self.additionalAccounts.map(\.platform)
        for platform in platforms {
            let accounts = try await Account.query(on: database)
                .filter(\.$name == Self.accountName)
                .filter(\.$platform == platform)
                .all()
            for account in accounts {
                try await account.delete(force: true, on: database)
            }
        }
    }

    /// Bulk-inserts every reading at `snapshotDate`. A raw multi-row insert both sidesteps the
    /// `@Timestamp(on: .create)` "stamp now" behaviour and is far faster than a round trip per row.
    private func insertMetrics(
        on sql: any SQLDatabase,
        readings: [(resourceID: Resource.IDValue, spec: MetricSpec)]
    ) async throws {
        guard !readings.isEmpty else { return }

        var query = SQLQueryString("INSERT INTO metrics (id, resource_id, reading, type, recorded_at) VALUES ")
        for (index, reading) in readings.enumerated() {
            if index > 0 {
                query.appendLiteral(", ")
            }
            query.appendLiteral("(")
            query.appendInterpolation(bind: UUID())
            query.appendLiteral(", ")
            query.appendInterpolation(bind: reading.resourceID)
            query.appendLiteral(", ")
            query.appendInterpolation(bind: reading.spec.reading)
            query.appendLiteral(", ")
            query.appendInterpolation(bind: reading.spec.type.rawValue)
            query.appendLiteral("::metric_type, ")
            query.appendInterpolation(bind: Self.snapshotDate)
            query.appendLiteral(")")
        }
        try await sql.raw(query).run()
    }
}
