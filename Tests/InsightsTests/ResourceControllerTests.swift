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
}
