import Fluent
import Vapor
import VaporToOpenAPI

/// Provides filtered metric-series reads and internal metric mutation handlers.
struct MetricController: RouteCollection {
  /// Ceiling for `?limit=`. Postgres rejects a negative `LIMIT` outright, and an unbounded one
  /// would hand back the whole series.
  private let maxLimit = 1000

  /// Mounts metric reads and the admin create under `/metrics`, plus the resource-scoped
  /// webhook route deployed services post to.
  func boot(routes: any RoutesBuilder) throws {
    let metrics = routes.grouped("metrics")

    metrics.get(use: index)
      .openAPI(
        tags: "Metrics",
        summary: "List metrics",
        query: .type(Filters.self),
        response: .type([Metric.Public].self)
      )
    metrics.grouped(Require.admin).post(use: create)
      .openAPI(
        tags: "Metrics",
        summary: "Create metric",
        body: .type(Metric.Create.self),
        response: .type(Metric.Public.self),
        statusCode: 201,
        auth: .bearer()
      )

    // The webhook endpoint. Each deployed ICICLE service is issued a token naming one resource,
    // and `Require.resourceScoped` compares that against this path — so a service can report its
    // own metrics and nothing else. Admins satisfy it too, for any resource.
    // The per-token limit runs after `Require.resourceScoped`, so it only counts callers that
    // were actually going to be served — and it keys on the token rather than the address,
    // because several deployed services may share one egress IP while only one is misbehaving.
    routes.grouped("resources", ":resourceID", "metrics")
      .grouped(Require.resourceScoped)
      .grouped(RateLimiter.perServiceToken)
      .post(use: createForResource)
      .openAPI(
        tags: "Metrics",
        summary: "Record a metric for one resource",
        body: .type(Metric.CreateForResource.self),
        response: .type(Metric.Public.self),
        statusCode: 201,
        auth: .bearer()
      )
    metrics.group(":metricID") { metric in
      metric.get(use: show)
        .openAPI(
          tags: "Metrics",
          summary: "Get metric by ID",
          response: .type(Metric.Public.self)
        )
      metric.grouped(Require.admin).delete(use: delete)
        .openAPI(
          tags: "Metrics",
          summary: "Delete metric",
          statusCode: 204,
          auth: .bearer()
        )
    }
  }

  /// Optional query parameters for narrowing a metric-series response.
  struct Filters: Content {
    /// Restricts readings to one resource identifier.
    var resourceID: Resource.IDValue?
    /// Restricts readings to one metric type.
    var type: MetricType?
    /// Maximum number of newest readings to return.
    var limit: Int?

    enum CodingKeys: String, CodingKey {
      case resourceID, type, limit
    }
  }

  @Sendable
  /// Lists newest-first metrics using optional resource, type, and limit filters.
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
  /// Records a validated metric reading for an existing resource.
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
  /// Records a reading for the resource named in the path.
  ///
  /// The resource comes from the path rather than the body because that is what the caller's
  /// token was checked against — taking it from anywhere else would let the two disagree.
  func createForResource(req: Request) async throws -> Response {
    guard let resourceID = req.parameters.get("resourceID", as: UUID.self) else {
      throw Abort(.badRequest, reason: "'resourceID' must be a UUID.")
    }

    let metric = try req.content.decode(Metric.CreateForResource.self).toModel(
      resourceID: resourceID)

    guard let resource = try await Resource.find(resourceID, on: req.db) else {
      throw Abort(.badRequest, reason: "Resource with ID: \(resourceID), not found.")
    }
    try await resource.$metrics.create(metric, on: req.db)

    return try await metric.toPublic().encodeResponse(status: .created, for: req)
  }

  @Sendable
  /// Returns one metric reading by identifier.
  func show(req: Request) async throws -> Metric.Public {
    guard let metric = try await Metric.find(req.parameters.get("metricID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    return metric.toPublic()
  }

  @Sendable
  /// Permanently deletes one metric reading.
  func delete(req: Request) async throws -> HTTPStatus {
    guard let metric = try await Metric.find(req.parameters.get("metricID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    try await metric.delete(on: req.db)
    return .noContent
  }
}
