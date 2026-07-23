// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "Insights",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 🐘 Vapor Queues Fluent driver for Postgres
        .package(url: "https://github.com/vapor-community/vapor-queues-fluent-driver.git", from: "3.0.0"),
        // 🍃 An expressive, performant, and extensible templating language built for Swift.
        .package(url: "https://github.com/vapor/leaf.git", from: "4.5.1"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        // 📖 Code-first OpenAPI generation from Vapor routes.
        .package(url: "https://github.com/dankinsoid/VaporToOpenAPI.git", from: "4.8.1"),

    ],
    targets: [
        .executableTarget(
            name: "Insights",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "QueuesFluentDriver", package: "vapor-queues-fluent-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "VaporToOpenAPI", package: "VaporToOpenAPI"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "InsightsTests",
            dependencies: [
                .target(name: "Insights"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings,
        ),
    ],
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
    ]
}
