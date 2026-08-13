// swift-tools-version:6.3
import PackageDescription

let package = Package(
  name: "Insights",
  platforms: [
    .macOS(.v13)
  ],
  dependencies: [
    // 💧 A server-side Swift web framework.
    .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
    // 🗄 An ORM for SQL and NoSQL databases.
    .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
    // 🐘 Fluent driver for Postgres.
    .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
    // 🟥 Vapor Queues Redis driver.
    .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.1"),
    // 📮 The queuing system itself. Direct, not just transitive, for XCTQueues' test driver.
    .package(url: "https://github.com/vapor/queues.git", from: "1.18.0"),
    // 🍃 An expressive, performant, and extensible templating language built for Swift.
    .package(url: "https://github.com/vapor/leaf.git", from: "4.5.1"),
    // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    // 📖 Code-first OpenAPI generation from Vapor routes.
    .package(url: "https://github.com/dankinsoid/VaporToOpenAPI.git", from: "4.8.1"),
    // 🍜 HTML Parsing for web scraping
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),

  ],
  targets: [
    .executableTarget(
      name: "Insights",
      dependencies: [
        .product(name: "Fluent", package: "fluent"),
        .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
        .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
        .product(name: "Leaf", package: "leaf"),
        .product(name: "Vapor", package: "vapor"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "VaporToOpenAPI", package: "VaporToOpenAPI"),
        .product(name: "SwiftSoup", package: "SwiftSoup"),
      ],
      swiftSettings: swiftSettings,
    ),
    .testTarget(
      name: "InsightsTests",
      dependencies: [
        .target(name: "Insights"),
        .product(name: "VaporTesting", package: "vapor"),
        .product(name: "Queues", package: "queues"),
        .product(name: "XCTQueues", package: "queues"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
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
