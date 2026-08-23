import Fluent
import Queues
import Redis
import Vapor
import VaporToOpenAPI

import struct Foundation.Date

/// Read-only operational projections for the administration console.
struct AdminInsightController: RouteCollection {
  func boot(routes: any RoutesBuilder) throws {
    let insights = routes.grouped("admin").grouped(Require.admin)

    insights.get("watermarks", use: watermarks)
      .openAPI(
        tags: "Admin Insights",
        summary: "List metric watermarks",
        response: .type([WatermarkInsight].self),
        auth: .bearer()
      )
    insights.get("queues", use: queues)
      .openAPI(
        tags: "Admin Insights",
        summary: "Inspect queue and scheduler health",
        response: .type(QueueInsight.self),
        auth: .bearer()
      )
    insights.get("failures", use: failures)
      .openAPI(
        tags: "Admin Insights",
        summary: "List recent collection failures",
        response: .type([JobFailureInsight].self),
        auth: .bearer()
      )
  }

  @Sendable
  func watermarks(request: Request) async throws -> [WatermarkInsight] {
    try await MetricWatermark.query(on: request.db)
      .with(\.$resource)
      .sort(\.$countedThrough, .descending)
      .all()
      .map { watermark in
        WatermarkInsight(
          id: watermark.id,
          resourceID: watermark.$resource.id,
          resourceName: watermark.resource.name,
          type: watermark.type,
          countedThrough: watermark.countedThrough,
          updatedAt: watermark.updatedAt,
        )
      }
  }

  @Sendable
  func queues(request: Request) async -> QueueInsight {
    let name = QueueName.metrics
    let key = name.makeKey(with: request.application.queues.configuration.persistenceKey)

    do {
      let pending = try await request.redis.llen(of: RedisKey(key)).get()
      let processing = try await request.redis.llen(of: RedisKey("\(key)-processing")).get()
      let heartbeatValue = try await request.redis
        .get(RedisKey(SchedulerHeartbeat.redisKey), as: String.self)
        .get()
      let heartbeat =
        heartbeatValue
        .flatMap(Double.init)
        .map(Date.init(timeIntervalSince1970:))
      let state: String
      if let heartbeat {
        state =
          Date().timeIntervalSince(heartbeat) > SchedulerHeartbeat.staleAfter ? "stale" : "healthy"
      } else {
        state = "notObserved"
      }

      return QueueInsight(
        queue: name.string,
        pending: pending,
        processing: processing,
        schedulerLastSeenAt: heartbeat,
        schedulerState: state,
      )
    } catch {
      // The operations console is most useful during an outage. Preserve a readable snapshot
      // instead of replacing every unrelated card with an HTTP error when Redis is unavailable.
      request.logger.error(
        "Could not inspect the metrics queue.",
        metadata: ["error": .string(String(reflecting: error))]
      )
      return QueueInsight(
        queue: name.string,
        pending: 0,
        processing: 0,
        schedulerLastSeenAt: nil,
        schedulerState: "unavailable",
      )
    }
  }

  @Sendable
  func failures(request: Request) async throws -> [JobFailureInsight] {
    let limit = min(max((try? request.query.get(Int.self, at: "limit")) ?? 50, 1), 200)
    return try await JobFailure.query(on: request.db)
      .sort(\.$failedAt, .descending)
      .limit(limit)
      .all()
      .map { $0.toInsight() }
  }
}
