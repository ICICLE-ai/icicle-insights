import Fluent
import Foundation
import Redis
import Testing
import Vapor
import VaporTesting

@testable import Insights

@Suite("Admin insight controller", .serialized)
struct AdminInsightControllerTests {
  @Test
  func `Watermarks are projected with resource context for admins only`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let countedThrough = Date().addingTimeInterval(-86_400)
      let watermark = MetricWatermark(
        resourceID: try resource.requireID(),
        type: .views,
        countedThrough: countedThrough
      )
      try await watermark.create(on: app.db)

      try await app.testing().test(
        .GET,
        "api/admin/watermarks",
        headers: app.adminAuth,
        afterResponse: { response async throws in
          #expect(response.status == .ok)
          let rows = try response.content.decode([WatermarkInsight].self)
          let row = try #require(rows.first)
          #expect(row.resourceID == resource.id)
          #expect(row.resourceName == resource.name)
          #expect(row.type == .views)
          #expect(abs(row.countedThrough.timeIntervalSince(countedThrough)) < 1)
        }
      )

      try await app.testing().test(
        .GET,
        "api/admin/watermarks",
        headers: app.userAuth,
        afterResponse: { response async throws in
          #expect(response.status == .forbidden)
        }
      )
    }
  }

  @Test
  func `Queue insight reports depth and a fresh scheduler heartbeat`() async throws {
    try await withInsightsApp { app in
      let heartbeat = Date()
      try await app.redis
        .set(
          RedisKey(SchedulerHeartbeat.redisKey),
          to: String(heartbeat.timeIntervalSince1970)
        )
        .get()

      try await app.testing().test(
        .GET,
        "api/admin/queues",
        headers: app.adminAuth,
        afterResponse: { response async throws in
          #expect(response.status == .ok)
          let insight = try response.content.decode(QueueInsight.self)
          #expect(insight.queue == "metrics")
          #expect(insight.pending >= 0)
          #expect(insight.processing >= 0)
          #expect(insight.schedulerState == "healthy")
          #expect(insight.schedulerLastSeenAt != nil)
        }
      )

      _ = try await app.redis.delete(RedisKey(SchedulerHeartbeat.redisKey)).get()
    }
  }

  @Test
  func `Queue insight remains readable when Redis is unavailable`() async throws {
    try await withInsightsApp(
      setUp: { app in
        app.redis.configuration = try RedisConfiguration(hostname: "127.0.0.1", port: 6399)
      },
      { app in
        try await app.testing().test(
          .GET,
          "api/admin/queues",
          headers: app.adminAuth,
          afterResponse: { response async throws in
            #expect(response.status == .ok)
            let insight = try response.content.decode(QueueInsight.self)
            #expect(insight.schedulerState == "unavailable")
            #expect(insight.pending == 0)
            #expect(insight.processing == 0)
          }
        )
      }
    )
  }

  @Test
  func `Recent failures are newest first and bounded by limit`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let accountID = try account.requireID()
      let older = JobFailure(
        accountID: accountID,
        job: "SyncGitHubOrgStats",
        subject: account.name,
        identifier: "older",
        details: "Older failure",
        severity: "warning",
        failedAt: Date().addingTimeInterval(-120)
      )
      let newest = JobFailure(
        accountID: accountID,
        job: "SyncGitHubOrgStats",
        subject: account.name,
        identifier: "newest",
        details: "Newest failure",
        severity: "critical"
      )
      try await older.create(on: app.db)
      try await newest.create(on: app.db)

      try await app.testing().test(
        .GET,
        "api/admin/failures?limit=1",
        headers: app.adminAuth,
        afterResponse: { response async throws in
          #expect(response.status == .ok)
          let rows = try response.content.decode([JobFailureInsight].self)
          #expect(rows.count == 1)
          #expect(rows.first?.identifier == "newest")
          #expect(rows.first?.accountID == accountID)
        }
      )
    }
  }
}
