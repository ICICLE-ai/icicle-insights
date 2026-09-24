import Fluent
import Foundation
import Queues
import Testing
import VaporTesting
import XCTQueues

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

  /// Valkey down at the moment of creation. The row used to be inserted with no due date and
  /// booked only after a successful dispatch, so this left it NULL, which the sweep's `<= now`
  /// filter never matches: the resource existed and was never collected, with nothing to say so.
  @Test
  func `A failed first dispatch still creates the resource due for the next sweep`()
    async throws
  {
    let driver = FlakyQueuesDriver()
    try await withInsightsApp(setUp: { $0.queues.use(custom: driver) }) { app in
      let account = try await makeAccount(on: app.db)
      let payload = Resource.Create(
        name: "insights", type: .repository, accountID: try account.requireID())

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          // Created, because it was: the row is committed and due. A 500 here would send the
          // admin to retry into the unique index.
          #expect(res.status == .created)
        },
      )

      // Read from the table rather than the response, so the due date is checked even when the
      // request itself went wrong.
      let created = try #require(try await Resource.query(on: app.db).first())
      let id = try created.requireID()
      #expect(try #require(created.nextCollectionAt) <= Date())
      #expect(driver.stored.withLockedValue { $0.isEmpty })

      // The next sweep is what rescues it, and the driver has recovered by then.
      try await CollectDueResources().run(context: queueContext(for: app))
      #expect(driver.stored.withLockedValue { $0.count } == 1)
      let rebooked = try #require(try await Resource.find(id, on: app.db)?.nextCollectionAt)
      #expect(rebooked > Date())
    }
  }

  /// The happy path keeps its lease: the dispatch books the next collection a full interval out,
  /// so the sweep does not dispatch the new resource a second time while its first job runs.
  @Test
  func `A dispatched first collection books the next one an interval out`() async throws {
    try await withQueueApp { app in
      let account = try await makeAccount(on: app.db)
      let payload = Resource.Create(
        name: "insights", type: .repository, accountID: try account.requireID(),
        collectionIntervalDays: 7)

      try await app.testing().test(
        .POST,
        "api/resources",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let id = try #require(try res.content.decode(Resource.Public.self).id)
          let next = try #require(try await Resource.find(id, on: app.db)?.nextCollectionAt)
          #expect(abs(next.timeIntervalSinceNow - 7 * 86_400) < 60)
          #expect(app.queues.asyncTest.all(SyncGitHubRepoStats.self).map(\.id) == [id])
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
  func `Index returns links for a resource whose Patra card names a hub resource`() async throws {
    try await withInsightsApp { app in
      let hfAccount = try await makeAccount(on: app.db, name: "hf", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "can_benchmark", type: .dataset)

      let patraAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .patra)
      let datasheet = try await makeResource(
        on: app.db, accountID: try patraAccount.requireID(),
        name: "continually-adapt-or-not-can-benchmark", type: .dataset)
      try await makePatraCard(
        on: app.db, resourceID: try datasheet.requireID(),
        hubResourceID: try hubResource.requireID())

      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode([Resource.Public].self)
          let found = try #require(returned.first { $0.id == datasheet.id })
          let links = try #require(found.links)
          #expect(links.count == 1)
          #expect(links.first?.id == hubResource.id)
          #expect(links.first?.name == "can_benchmark")
          #expect(links.first?.platform == .huggingface)
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
  func `Show returns a link for a resource whose Patra card names a hub resource`() async throws {
    try await withInsightsApp { app in
      let hfAccount = try await makeAccount(on: app.db, name: "hf", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "can_benchmark", type: .dataset)

      let patraAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .patra)
      let datasheet = try await makeResource(
        on: app.db, accountID: try patraAccount.requireID(),
        name: "continually-adapt-or-not-can-benchmark", type: .dataset)
      try await makePatraCard(
        on: app.db, resourceID: try datasheet.requireID(),
        hubResourceID: try hubResource.requireID())

      try await app.testing().test(
        .GET,
        "api/resources/\(datasheet.requireID())",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Resource.Public.self)
          let links = try #require(returned.links)
          #expect(links.count == 1)
          #expect(links.first?.id == hubResource.id)
          #expect(links.first?.name == "can_benchmark")
          #expect(links.first?.platform == .huggingface)
        },
      )
    }
  }

  @Test
  func `Show returns two links when a Patra card names both a hub and a repository resource`()
    async throws
  {
    try await withInsightsApp { app in
      let hfAccount = try await makeAccount(on: app.db, name: "hf", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "can_benchmark", type: .dataset)

      let ghAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let repositoryResource = try await makeResource(
        on: app.db, accountID: try ghAccount.requireID(), name: "can-benchmark", type: .repository)

      let patraAccount = try await makeAccount(
        on: app.db, name: "icicle-ai-patra", platform: .patra)
      let datasheet = try await makeResource(
        on: app.db, accountID: try patraAccount.requireID(),
        name: "continually-adapt-or-not-can-benchmark", type: .dataset)
      try await makePatraCard(
        on: app.db, resourceID: try datasheet.requireID(),
        hubResourceID: try hubResource.requireID(),
        repositoryResourceID: try repositoryResource.requireID())

      try await app.testing().test(
        .GET,
        "api/resources/\(datasheet.requireID())",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Resource.Public.self)
          let links = try #require(returned.links)
          #expect(links.count == 2)
          let linkedIDs = Set(links.compactMap(\.id))
          let expectedIDs = Set([hubResource.id, repositoryResource.id].compactMap { $0 })
          #expect(linkedIDs == expectedIDs)
        },
      )
    }
  }

  @Test
  func `Show returns an empty links array, not nil, for a resource with no Patra cards`()
    async throws
  {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())

      try await app.testing().test(
        .GET,
        "api/resources/\(resource.requireID())",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Resource.Public.self)
          // Pinning the contract: `show` always eager-loads Patra cards, so "none found" is a
          // loaded empty array, never the nil that would mean "not requested".
          #expect(returned.links == [])
        },
      )
    }
  }

  @Test
  func `Index still succeeds after a Patra card's linked resource is soft-deleted`() async throws {
    try await withInsightsApp { app in
      // Reproduces the eager-load trap `SyncPatraCatalog.register` already documents on its own
      // `.with(\.$resource, withDeleted: true)`: `hubResource`/`repositoryResource` are
      // `@OptionalParent`, and Fluent throws `missingParentError` — not "nil parent" — for a
      // non-nil id whose row a plain (non-`withDeleted`) eager load excludes. `ResourceController
      // .delete` is a soft delete, so this is reachable from the admin console with no raw SQL.
      let hfAccount = try await makeAccount(on: app.db, name: "hf", platform: .huggingface)
      let hubResource = try await makeResource(
        on: app.db, accountID: try hfAccount.requireID(), name: "can_benchmark", type: .dataset)
      let hubResourceID = try hubResource.requireID()

      let patraAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .patra)
      let datasheet = try await makeResource(
        on: app.db, accountID: try patraAccount.requireID(),
        name: "continually-adapt-or-not-can-benchmark", type: .dataset)
      try await makePatraCard(
        on: app.db, resourceID: try datasheet.requireID(), hubResourceID: hubResourceID)

      // Soft delete, exactly what `ResourceController.delete` does — not `force: true`, which
      // would sidestep the bug by removing the row (and the foreign key) outright.
      try await app.testing().test(
        .DELETE,
        "api/resources/\(hubResourceID)",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
        },
      )

      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          // Before the fix, this 500s — the eager load of the soft-deleted `hubResource` throws
          // `missingParentError` and every caller of the catalog's only list endpoint is broken,
          // including the admin console that would otherwise let someone notice and fix it.
          #expect(res.status == .ok)
          let returned = try res.content.decode([Resource.Public].self)
          #expect(returned.contains { $0.id == datasheet.id })
        },
      )
    }
  }

  /// One level down from the test above. Deleting an account now requires deleting its
  /// resources first, so the normal path leaves a card pointing at a deleted resource whose
  /// account is deleted too, and a plain load of that account throws the same `missingParent`.
  @Test
  func `Index still succeeds after a linked resource and its account are both deleted`()
    async throws
  {
    try await withInsightsApp { app in
      let hfAccount = try await makeAccount(on: app.db, name: "hf", platform: .huggingface)
      let hfAccountID = try hfAccount.requireID()
      let hubResource = try await makeResource(
        on: app.db, accountID: hfAccountID, name: "can_benchmark", type: .dataset)
      let hubResourceID = try hubResource.requireID()

      let patraAccount = try await makeAccount(on: app.db, name: "icicle-ai", platform: .patra)
      let datasheet = try await makeResource(
        on: app.db, accountID: try patraAccount.requireID(), name: "datasheet", type: .dataset)
      try await makePatraCard(
        on: app.db, resourceID: try datasheet.requireID(), hubResourceID: hubResourceID)

      // The console's order: the resource first, then the account it no longer blocks.
      for path in ["api/resources/\(hubResourceID)", "api/accounts/\(hfAccountID)"] {
        try await app.testing().test(
          .DELETE, path, headers: app.adminAuth,
          afterResponse: { res async throws in #expect(res.status == .noContent) })
      }

      for path in ["api/resources", "api/resources/\(try datasheet.requireID())"] {
        try await app.testing().test(
          .GET, path,
          afterResponse: { res async throws in #expect(res.status == .ok) })
      }
    }
  }

  /// A Patra model with two cards, the newer carrying a full description, next to a GitHub
  /// repository with none. Read as raw JSON rather than through `Resource.Public`, because the
  /// shape on the wire is the contract the dashboard's Models page is built against.
  @Test
  func `Index returns the newest Patra card for a Patra resource and none for a GitHub one`()
    async throws
  {
    try await withInsightsApp { app in
      let github = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
      let repository = try await makeResource(
        on: app.db, accountID: try github.requireID(), name: "insights", type: .repository)

      let patra = try await makeAccount(on: app.db, name: "icicleai", platform: .patra)
      let model = try await makeResource(
        on: app.db, accountID: try patra.requireID(), name: "bioclip 2 (via pybioclip)",
        type: .model)
      let modelID = try model.requireID()

      let older = PatraCard(
        resourceID: modelID, cardUUID: "bioclip-old", version: "v1.0",
        cardUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
      older.cardDescription = "An earlier card."
      try await older.create(on: app.db)

      let newer = PatraCard(
        resourceID: modelID, cardUUID: "bioclip-new", version: "v2.0",
        cardUpdatedAt: Date(timeIntervalSince1970: 1_779_000_000),
        sourceURL: "https://huggingface.co/imageomics/bioclip-2")
      newer.cardDescription = "Biology foundation model."
      newer.author = "John Bradley / Imageomics Institute"
      newer.category = "classification"
      newer.license = "MIT License"
      newer.framework = "PyTorch / OpenCLIP"
      newer.modelType = "multimodal biological foundation model"
      newer.inputType = "images"
      newer.accuracy = 0.88
      newer.keywords = "biology, taxonomy, zero-shot"
      newer.isGated = false
      try await newer.create(on: app.db)

      try await app.testing().test(
        .GET, "api/resources",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let rows = try #require(
            try JSONSerialization.jsonObject(with: Data(res.body.string.utf8))
              as? [[String: Any]])
          let modelRow = try #require(rows.first { $0["id"] as? String == modelID.uuidString })
          let card = try #require(modelRow["card"] as? [String: Any])

          #expect(card["kind"] as? String == "model")
          #expect(card["uuid"] as? String == "bioclip-new")
          #expect(card["version"] as? String == "v2.0")
          #expect(card["updatedAt"] as? String == "2026-05-17T06:40:00Z")
          #expect(card["description"] as? String == "Biology foundation model.")
          #expect(card["author"] as? String == "John Bradley / Imageomics Institute")
          #expect(card["modelType"] as? String == "multimodal biological foundation model")
          #expect(card["accuracy"] as? Double == 0.88)
          #expect(card["keywords"] as? [String] == ["biology", "taxonomy", "zero-shot"])
          #expect(card["gated"] as? Bool == false)
          #expect(card["sourceURL"] as? String == "https://huggingface.co/imageomics/bioclip-2")
          // Datasheet-only fields: present, and null.
          #expect(card["size"] is NSNull)
          #expect(card["format"] is NSNull)
          #expect(card["publicationYear"] is NSNull)

          let repositoryRow = try #require(
            rows.first { $0["id"] as? String == repository.id?.uuidString })
          #expect(repositoryRow["card"] == nil || repositoryRow["card"] is NSNull)
        })
    }
  }

  @Test
  func `Show returns a datasheet's card with kind datasheet`() async throws {
    try await withInsightsApp { app in
      let patra = try await makeAccount(on: app.db, name: "icicleai", platform: .patra)
      let dataset = try await makeResource(
        on: app.db, accountID: try patra.requireID(),
        name: "continually adapt or not (can) benchmark", type: .dataset)
      let sheet = PatraCard(
        resourceID: try dataset.requireID(), cardUUID: "2a7b541d-d3d4-4969-8639-576830ad3d95",
        cardUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000))
      sheet.cardDescription = "The CAN Benchmark is a curated ICICLE benchmark."
      sheet.author = "ICICLE AI Institute"
      sheet.category = "Camera trap"
      sheet.size = "~1.56 GB (1,000-10,000 images)"
      sheet.publicationYear = 2025
      try await sheet.create(on: app.db)

      try await app.testing().test(
        .GET, "api/resources/\(dataset.requireID())",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let card = try #require(try res.content.decode(Resource.Public.self).card)
          #expect(card.kind == .datasheet)
          #expect(card.uuid == "2a7b541d-d3d4-4969-8639-576830ad3d95")
          #expect(card.author == "ICICLE AI Institute")
          #expect(card.size == "~1.56 GB (1,000-10,000 images)")
          #expect(card.publicationYear == 2025)
          #expect(card.framework == nil)
          #expect(card.keywords == nil)
        })
    }
  }

  /// The generated document is what a client generates its types from, so `card` has to appear
  /// there with its two required keys and its `kind` values listed, not as a bare string.
  @Test
  func `The OpenAPI document describes the resource's card`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET, "openapi.json",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let document = try #require(
            try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any])
          let schemas = try #require(
            (document["components"] as? [String: Any])?["schemas"] as? [String: Any])

          let resource = try #require(schemas["ResourcePublic"] as? [String: Any])
          let resourceProperties = try #require(resource["properties"] as? [String: Any])
          #expect(resourceProperties["card"] != nil)

          let card = try #require(schemas["PatraCardPublic"] as? [String: Any])
          #expect(Set(card["required"] as? [String] ?? []) == ["kind", "uuid"])
          let cardProperties = try #require(card["properties"] as? [String: Any])
          #expect(cardProperties.count == 18)

          let kind = try #require(schemas["PatraCardKind"] as? [String: Any])
          #expect(kind["enum"] as? [String] == ["model", "datasheet"])
        })
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
