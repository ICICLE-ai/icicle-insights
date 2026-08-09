import Fluent
import Vapor
import VaporToOpenAPI

struct MetricController: RouteCollection {
  /// Ceiling for `?limit=`. Postgres rejects a negative `LIMIT` outright, and an unbounded one
  /// would hand back the whole series.
  private let maxLimit = 1000

  func boot(routes: any RoutesBuilder) throws {
    let metrics = routes.grouped("metrics")

    metrics.get(use: index)
      .openAPI(
        tags: "Metrics",
        summary: "List metrics",
        query: .type(Filters.self),
        response: .type([Metric.Public].self)
      )
    // Mutating routes stay disabled until auth middleware protects them. The handlers
    // below are kept intact so re-enabling is just uncommenting the registrations.
    // metrics.post(use: create)
    //     .openAPI(
    //         tags: "Metrics",
    //         summary: "Create metric",
    //         body: .type(Metric.Create.self),
    //         response: .type(Metric.Public.self),
    //         statusCode: 201
    //     )
    metrics.group(":metricID") { metric in
      metric.get(use: show)
        .openAPI(
          tags: "Metrics",
          summary: "Get metric by ID",
          response: .type(Metric.Public.self)
        )
      // metric.delete(use: delete)
      //     .openAPI(
      //         tags: "Metrics",
      //         summary: "Delete metric",
      //         statusCode: 204
      //     )
    }
  }

  struct Filters: Content {
    var resourceID: Resource.IDValue?
    var type: MetricType?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
      case resourceID, type, limit
    }
  }

  @Sendable
  func index(req: Request) async throws -> [Metric.Public] {
    let filters = try req.query.decode(Filters.self)

    var query = Metric.query(on: req.db).sort(\.$recordedAt, .descending)
    if let resourceID = filters.resourceID {
      query = query.filter(\.$resource.$id == resourceID)
    }
    if let type = filters.type {
      query = query.filter(\.$type == type)
    }
    // Defaulted, not left open: readings accumulate every sweep. Rows are newest-first and
    // reversed below, so a capped response is the most recent window, not a bad truncation.
    query = try query.limit(requireInRange(filters.limit ?? maxLimit, 1...maxLimit, "limit"))

    // Most recent `limit` rows, returned oldest→newest for the chart's x-axis.
    return try await query.all().reversed().map { $0.toPublic() }
  }

  @Sendable
  func create(req: Request) async throws -> Response {
    let metric = try req.content.decode(Metric.Create.self).toModel()

    guard let resource = try await Resource.find(metric.$resource.id, on: req.db)
    else {
      throw Abort(.badRequest, reason: "Resource with ID: \(metric.$resource.id), not found.")
    }
    try await resource.$metrics.create(metric, on: req.db)

    return try await metric.toPublic().encodeResponse(status: .created, for: req)
  }

  @Sendable
  func show(req: Request) async throws -> Metric.Public {
    guard let metric = try await Metric.find(req.parameters.get("metricID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    return metric.toPublic()
  }

  @Sendable
  func delete(req: Request) async throws -> HTTPStatus {
    guard let metric = try await Metric.find(req.parameters.get("metricID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    try await metric.delete(on: req.db)
    return .noContent
  }
}
