import Fluent
import Testing
import VaporTesting

@testable import Insights

@Suite("Metric Controller", .serialized)
struct MetricControllerTests {
  @Test
  func `Create metric`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let payload = Metric.Create(reading: 100, type: .stars, resourceID: try resource.requireID())

      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
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
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let payload = Metric.Create(reading: -1, type: .stars, resourceID: try resource.requireID())

      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
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
  func `Update changes reading and type`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let metric = try await makeMetric(on: app.db, resourceID: try resource.requireID())
      let payload = Metric.Update(reading: 250, type: .forks)

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          let returned = try res.content.decode(Metric.Public.self)
          #expect(returned.reading == 250)
          #expect(returned.type == .forks)
        },
      )
    }
  }

  @Test
  func `Update rejects a negative reading`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let metric = try await makeMetric(on: app.db, resourceID: try resource.requireID())
      let payload = Metric.Update(reading: -1)

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
          let model = try #require(await Metric.find(metric.id, on: app.db))
          #expect(model.reading == 1)
        },
      )
    }
  }

  @Test
  func `Create with missing resource is a bad request`() async throws {
    try await withInsightsApp { app in
      let payload = Metric.Create(reading: 1, type: .stars, resourceID: UUID())

      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
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
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      for reading in [1.0, 2.0, 3.0] {
        _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: reading)
      }

      try await app.testing().test(
        .GET,
        "api/metrics",
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
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: 10, type: .stars)
      _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: 20, type: .stars)
      _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: 5, type: .downloads)

      try await app.testing().test(
        .GET,
        "api/metrics?type=stars",
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
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      let first = try await makeResource(
        on: app.db, accountID: accountID, name: "insights", type: .model)
      let second = try await makeResource(
        on: app.db, accountID: accountID, name: "insights-cli", type: .package)
      let firstID = try first.requireID()
      _ = try await makeMetric(on: app.db, resourceID: firstID, reading: 1)
      _ = try await makeMetric(on: app.db, resourceID: firstID, reading: 2)
      _ = try await makeMetric(on: app.db, resourceID: try second.requireID(), reading: 3)

      try await app.testing().test(
        .GET,
        "api/metrics?resourceID=\(firstID)",
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
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      for reading in [1.0, 2.0, 3.0, 4.0, 5.0] {
        _ = try await makeMetric(on: app.db, resourceID: resourceID, reading: reading)
      }

      try await app.testing().test(
        .GET,
        "api/metrics?limit=3",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          // Most recent 3 (4,5 newest) returned oldest→newest.
          let readings = try res.content.decode([Metric.Public].self).compactMap(\.reading)
          #expect(readings == [3, 4, 5])
        },
      )
    }
  }

  // The `-> Void` is load-bearing: VaporTesting exports a generic `withInsightsApp<T>` that skips
  // `configure`, and a single-expression closure returns the tester, which would select that
  // overload and leave the app with no routes.
  @Test(arguments: ["-1", "0", "1001"])
  func `Index rejects an out of range limit`(limit: String) async throws {
    try await withInsightsApp { app -> Void in
      try await app.testing().test(
        .GET,
        "api/metrics?limit=\(limit)",
        afterResponse: { res async throws in
          #expect(res.status == .badRequest)
        },
      )
    }
  }

  @Test
  func `Show metric by ID`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let metric = try await makeMetric(on: app.db, resourceID: try resource.requireID())
      let metricID = try metric.requireID()

      try await app.testing().test(
        .GET,
        "api/metrics/\(metricID)",
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
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let metric = try await makeMetric(on: app.db, resourceID: try resource.requireID())

      try await app.testing().test(
        .DELETE,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
          let model = try await Metric.find(metric.id, on: app.db)
          #expect(model == nil)
        },
      )
    }
  }

  // MARK: - All-time totals
  //
  // The API owns the `*AllTime` rows: it refuses to be handed one and moves it itself on every
  // accepted write. `.stars` is used wherever a test needs a type with no all-time counterpart.

  @Test
  func `Create folds the reading into its all-time total`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let payload = Metric.Create(reading: 120, type: .downloads, resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 120)
        },
      )

      // Second reading accumulates rather than replacing: the total is a running sum.
      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(
            Metric.Create(reading: 30, type: .downloads, resourceID: resourceID))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 150)
        },
      )
    }
  }

  @Test
  func `Create leaves gauges without an all-time counterpart alone`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()

      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(Metric.Create(reading: 42, type: .stars, resourceID: resourceID))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          let count = try await Metric.query(on: app.db).count()
          #expect(count == 1)
        },
      )
    }
  }

  @Test(arguments: [MetricType.downloadsAllTime, .clonesAllTime, .viewsAllTime, .pullsAllTime])
  func `Create rejects a derived all-time type`(type: MetricType) async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let payload = Metric.Create(reading: 900, type: type, resourceID: try resource.requireID())

      try await app.testing().test(
        .POST,
        "api/metrics",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(payload) },
        afterResponse: { res async throws in
          #expect(res.status == .unprocessableEntity)
          let count = try await Metric.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Update moves the all-time total by the difference`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let metric = try await makeMetric(
        on: app.db, resourceID: resourceID, reading: 100, type: .downloads)
      try await Metric.adjustAllTime(
        on: app.db, resourceID: resourceID, type: .downloads, delta: 100)

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(Metric.Update(reading: 175, type: nil)) },
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          // 100 + (175 - 100), not 175: the total accumulates many readings, so restating one
          // of them moves it by however much that reading moved.
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 175)
        },
      )

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(Metric.Update(reading: 25, type: nil)) },
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 25)
        },
      )
    }
  }

  @Test
  func `Update to another type moves both all-time totals`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let metric = try await makeMetric(
        on: app.db, resourceID: resourceID, reading: 60, type: .downloads)
      try await Metric.adjustAllTime(
        on: app.db, resourceID: resourceID, type: .downloads, delta: 60)

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(Metric.Update(reading: nil, type: .clones))
        },
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 0)
          #expect(try await allTimeReading(app, resourceID, .clonesAllTime) == 60)
        },
      )
    }
  }

  @Test
  func `Update rejects switching a reading to a derived type`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let metric = try await makeMetric(
        on: app.db, resourceID: try resource.requireID(), reading: 5, type: .downloads)

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in
          try req.content.encode(Metric.Update(reading: nil, type: .downloadsAllTime))
        },
        afterResponse: { res async throws in
          #expect(res.status == .unprocessableEntity)
          let unchanged = try await Metric.find(metric.id, on: app.db)
          #expect(unchanged?.type == .downloads)
        },
      )
    }
  }

  @Test
  func `Update rejects editing an all-time row`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let total = try await makeMetric(
        on: app.db, resourceID: try resource.requireID(), reading: 800, type: .downloadsAllTime)

      try await app.testing().test(
        .PATCH,
        "api/metrics/\(total.requireID())",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(Metric.Update(reading: 1, type: nil)) },
        afterResponse: { res async throws in
          #expect(res.status == .unprocessableEntity)
          let unchanged = try await Metric.find(total.id, on: app.db)
          #expect(unchanged?.reading == 800)
        },
      )
    }
  }

  @Test
  func `Delete withdraws the reading from its all-time total`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let metric = try await makeMetric(
        on: app.db, resourceID: resourceID, reading: 40, type: .downloads)
      try await Metric.adjustAllTime(
        on: app.db, resourceID: resourceID, type: .downloads, delta: 100)

      try await app.testing().test(
        .DELETE,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 60)
        },
      )
    }
  }

  @Test
  func `Delete floors an over-withdrawn all-time total at zero`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      // A reading larger than the total it belongs to: history and deltas disagree, which the
      // clamp turns into a readable zero rather than a negative lifetime count.
      let metric = try await makeMetric(
        on: app.db, resourceID: resourceID, reading: 500, type: .downloads)
      try await Metric.adjustAllTime(
        on: app.db, resourceID: resourceID, type: .downloads, delta: 10)

      try await app.testing().test(
        .DELETE,
        "api/metrics/\(metric.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 0)
        },
      )
    }
  }

  @Test
  func `Scoped token posting a reading folds it into the all-time total`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), type: .service)
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 12, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
          #expect(try await allTimeReading(app, resourceID, .downloadsAllTime) == 12)
        },
      )
    }
  }

  @Test
  func `Scoped token cannot post a derived all-time type`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), type: .service)
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(
            Metric.CreateForResource(reading: 5_000, type: .downloadsAllTime))
        },
        afterResponse: { res async throws in
          #expect(res.status == .unprocessableEntity)
          let count = try await Metric.query(on: app.db).count()
          #expect(count == 0)
        },
      )
    }
  }

  @Test
  func `Delete of an all-time row leaves no other total behind`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let total = try await makeMetric(
        on: app.db, resourceID: resourceID, reading: 800, type: .downloadsAllTime)

      // Deleting the total is the last correction path left, so it must not recurse into
      // withdrawing itself from a second row.
      try await app.testing().test(
        .DELETE,
        "api/metrics/\(total.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          #expect(res.status == .noContent)
          let remaining = try await Metric.query(on: app.db).count()
          #expect(remaining == 0)
        },
      )
    }
  }
}

/// Reads one all-time total's current value, or 0 when the row does not exist yet.
private func allTimeReading(
  _ app: Application,
  _ resourceID: Resource.IDValue,
  _ type: MetricType,
) async throws -> Double {
  try await Metric.query(on: app.db)
    .filter(\.$resource.$id == resourceID)
    .filter(\.$type == type)
    .first()?
    .reading ?? 0
}
