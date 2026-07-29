import Fluent
import Foundation
@testable import Insights
import Testing
import Vapor
import VaporTesting

/// Standard test harness: boots a `.testing` app (which connects to the `test` database),
/// migrates, runs the test, then reverts and shuts down.
func withApp(_ test: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app)
        try await app.autoMigrate()
        try await test(app)
        try await app.autoRevert()
    } catch {
        try? await app.autoRevert()
        try await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

// MARK: - Fixtures

/// An expiration a year out. The vault endpoints reject dates in the past, so payloads must not
/// hard-code a year that will eventually go stale.
func futureExpires() -> Vault.Expires {
    let calendar = Calendar(identifier: .gregorian)
    let date = calendar.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return Vault.Expires(day: components.day ?? 1, month: components.month ?? 1, year: components.year ?? 2100)
}

@discardableResult
func makeAccount(
    on db: any Database,
    name: String = "octocat",
    platform: Platform = .github,
    followers: Int = 0,
) async throws -> Account {
    let account = Account(name: name, platform: platform, followers: followers)
    try await account.create(on: db)
    return account
}

@discardableResult
func makeResource(
    on db: any Database,
    accountID: Account.IDValue,
    name: String = "insights",
    type: ResourceType = .model,
) async throws -> Resource {
    let resource = Resource(name: name, type: type, accountID: accountID)
    try await resource.create(on: db)
    return resource
}

@discardableResult
func makeMetric(
    on db: any Database,
    resourceID: Resource.IDValue,
    reading: Double = 1,
    type: MetricType = .stars,
) async throws -> Metric {
    let metric = Metric(resourceID: resourceID, reading: reading, type: type)
    try await metric.create(on: db)
    return metric
}

@discardableResult
func makeRelease(
    on db: any Database,
    resourceID: Resource.IDValue,
    version: String = "1.0.0",
) async throws -> Release {
    let release = Release(resourceID: resourceID, version: version)
    try await release.create(on: db)
    return release
}

@discardableResult
func makeVault(
    on db: any Database,
    accountID: Account.IDValue,
    name: String = "github-token",
) async throws -> Vault {
    let vault = Vault(accountID: accountID, name: name)
    try await vault.create(on: db)
    return vault
}
