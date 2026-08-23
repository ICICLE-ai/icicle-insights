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
      metric.grouped(Require.admin).patch(use: update)
        .openAPI(
          tags: "Metrics",
          summary: "Update metric",
          body: .type(Metric.Update.self),
          response: .type(Metric.Public.self),
          auth: .bearer()
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
  ///
  /// The reading is folded into its all-time counterpart, so a hand-recorded observation moves
  /// the lifetime figure the same way a collected one does. `Metric.Create.toModel` has already
  /// rejected an attempt to write that counterpart directly.
  ///
  /// For a Hugging Face resource the fold into `downloadsAllTime` is temporary: the Hub reports
  /// its own lifetime figure and `SyncHuggingFaceHubStats` writes it with `setAllTime`, replacing
  /// whatever this added at the next sweep. That is correct — the platform owns that number —
  /// and is not a bug to fix here.
  func create(req: Request) async throws -> Response {
    let metric = try req.content.decode(Metric.Create.self).toModel()

    guard let resource = try await Resource.find(metric.$resource.id, on: req.db)
    else {
      throw Abort(.badRequest, reason: "Resource with ID: \(metric.$resource.id), not found.")
    }
    try await resource.$metrics.create(metric, on: req.db)
    try await Metric.adjustAllTime(
      on: req.db,
      resourceID: metric.$resource.id,
      type: metric.type,
      delta: metric.reading
    )

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
    // A client that retries this POST now moves the all-time total twice as well as writing a
    // second row. The duplicate row was always the outcome of a retry here; the total simply
    // follows it. Services needing exactly-once delivery must deduplicate before posting.
    try await Metric.adjustAllTime(
      on: req.db,
      resourceID: resourceID,
      type: metric.type,
      delta: metric.reading
    )

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
  /// Corrects a manually recorded reading's value or type, carrying the correction into the
  /// all-time total.
  ///
  /// The total moves by the *difference*, not the new value: it is an accumulation of many
  /// readings, so restating one of them changes it by however much that one reading changed. A
  /// type change is two corrections — the old contribution leaves its total and the new value
  /// joins another.
  ///
  /// The row itself must be a collected reading. An all-time row is server-derived; editing one
  /// would set a figure the next fold immediately contradicts.
  func update(req: Request) async throws -> Metric.Public {
    guard let metric = try await Metric.find(req.parameters.get("metricID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    _ = try requireRecordable(metric.type)
    let newValues = try req.content.decode(Metric.Update.self)
    let previousReading = metric.reading
    let previousType = metric.type

    if let reading = newValues.reading {
      metric.reading = try requireNonNegative(reading, "reading")
    }
    if let type = newValues.type {
      metric.type = try requireRecordable(type)
    }

    try await metric.save(on: req.db)

    // The unchanged-type case is one net delta, not a withdraw-then-add against the same total,
    // and the two are not interchangeable: `adjustAllTime` floors at zero, so withdrawing first
    // can clip a total that the addition then rebuilds from the floor. A reading corrected from
    // 100 to 175 against a total of 50 is +75 → 125; done in two steps it is 0 → 175.
    if previousType == metric.type {
      try await Metric.adjustAllTime(
        on: req.db,
        resourceID: metric.$resource.id,
        type: metric.type,
        delta: metric.reading - previousReading
      )
    } else {
      try await Metric.adjustAllTime(
        on: req.db,
        resourceID: metric.$resource.id,
        type: previousType,
        delta: -previousReading
      )
      try await Metric.adjustAllTime(
        on: req.db,
        resourceID: metric.$resource.id,
        type: metric.type,
        delta: metric.reading
      )
    }

    return metric.toPublic()
  }

  @Sendable
  /// Permanently deletes one metric reading, withdrawing it from its all-time total.
  ///
  /// Deleting an all-time row itself is allowed — it is the only remaining way to correct a
  /// total that has gone wrong. It does not reset collection: `MetricWatermark.countedThrough`
  /// still marks those days as folded, so the rebuilt row starts from the next uncounted day.
  func delete(req: Request) async throws -> HTTPStatus {
    guard let metric = try await Metric.find(req.parameters.get("metricID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    let withdrawn = metric.reading
    let type = metric.type
    let resourceID = metric.$resource.id

    try await metric.delete(on: req.db)
    // Guarded, not delegated: `MetricType.allTime` maps an all-time type to *itself*, so an
    // all-time row would otherwise be withdrawn from its own series. Deleting the only such row
    // is harmless — the negative delta finds nothing and stops — but where a duplicate total
    // exists, and the unguarded API used to allow those, it would silently corrupt the survivor.
    if !type.isAllTime {
      try await Metric.adjustAllTime(
        on: req.db, resourceID: resourceID, type: type, delta: -withdrawn)
    }
    return .noContent
  }
}
