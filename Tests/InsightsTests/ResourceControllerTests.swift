import Fluent
import Testing
import VaporTesting

@testable import Insights

@Suite("Resource Controller", .serialized)
struct ResourceControllerTests {
  @Test
  func `Create lowercases the name`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Resource.Create(
        name: "Insights", type: .model, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let returned = try res.content.decode(Resource.Public.self)
          #expect(returned.name == "insights")
          #expect(returned.accountID == account.id)
        },
      )
    }
  }

  @Test
  func `Create trims surrounding whitespace from the name`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Resource.Create(
        name: "  Insights  ", type: .model, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let returned = try res.content.decode(Resource.Public.self)
          #expect(returned.name == "insights")
        },
      )
    }
  }

  @Test
  func `Create rejects a blank name`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Resource.Create(name: " ", type: .model, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let count = try await Resource.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Create rejects a duplicate name and type for the same account`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      _ = try await makeResource(on: app.db, accountID: accountID, name: "insights", type: .model)

      let payload = Resource.Create(name: "Insights", type: .model, accountID: accountID)
      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .conflict)
          let count = try await Resource.query(on: app.db).count()
          #expect(count == 1)
        },
      )
    }
  }

  @Test
  func `Create with missing account is a bad request`() async throws {
    try await withInsightsApp { app in
      let payload = Resource.Create(name: "insights", type: .model, accountID: UUID())

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let count = try await Resource.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Index returns all resources`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      _ = try await makeResource(on: app.db, accountID: accountID, name: "insights", type: .model)
      _ = try await makeResource(
        on: app.db, accountID: accountID, name: "insights-cli", type: .package)

      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let names = try res.content.decode([Resource.Public].self).compactMap(\.name).sorted()
          #expect(names == ["insights", "insights-cli"])
        },
      )
    }
  }

  @Test
  func `Show resource by ID`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()

      try await app.testing().test(
        .GET,
        "api/resources/\(resourceID)",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Resource.Public.self)
          #expect(returned.id == resourceID)
        },
      )
    }
  }

  @Test
  func `Update changes name, type, and cadence`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let payload = Resource.Update(name: "Renamed", type: .package, collectionIntervalDays: 3)

      try await app.testing().test(
        .PATCH,
        "api/resources/\(resource.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Resource.Public.self)
          #expect(returned.name == "renamed")
          #expect(returned.type == .package)
          #expect(returned.collectionIntervalDays == 3)
        },
      )
    }
  }

  @Test
  func `Update rejects a cadence beyond the account platform's retention window`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, platform: .github)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let payload = Resource.Update(collectionIntervalDays: 30)

      try await app.testing().test(
        .PATCH,
        "api/resources/\(resource.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let model = try #require(await Resource.find(resource.id, on: app.db))
          #expect(model.collectionIntervalDays == Resource.defaultCollectionIntervalDays)
        },
      )
    }
  }

  @Test
  func `Update with unknown resource is not found`() async throws {
    try await withInsightsApp { app in
      let payload = Resource.Update(name: "Renamed")

      try await app.testing().test(
        .PATCH,
        "api/resources/\(UUID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .notFound)
        },
      )
    }
  }

  @Test
  func `Delete resource`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .DELETE,
        "api/resources/\(resource.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
          let model = try await Resource.find(resource.id, on: app.db)
          #expect(model == nil)
        },
      )
    }
  }

  @Test
  func `Create rejects a GitHub cadence with no headroom for delay`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, platform: .github)
      // 14 was accepted before: it equals the traffic retention window exactly, so any delay at
      // all loses days and no backoff value can protect it.
      let payload = Resource.Create(
        name: "insights", type: .repository, accountID: try account.requireID(),
        collectionIntervalDays: 14)

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
        },
      )
    }
  }

  @Test
  func `The Hub keeps its longer cadence, having no window to lose`() {
    // The Hub reports downloadsAllTime outright, so a missed sweep costs series density and never
    // all-time correctness. Restricting it would buy nothing.
    #expect(Platform.huggingface.maxCollectionIntervalDays == 30)
    #expect(Platform.huggingface.retentionWindowDays == nil)
    #expect(Platform.github.maxCollectionIntervalDays == 7)
    #expect(Platform.github.retentionWindowDays == 14)
  }
}
