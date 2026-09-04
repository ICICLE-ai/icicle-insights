import Fluent
import Queues
import Vapor
import VaporToOpenAPI

/// Serves resource catalog endpoints and dispatches collection when a resource is created.
struct ResourceController: RouteCollection {
  /// Mounts resource routes under `/resources`.
  func boot(routes: any RoutesBuilder) throws {
    let resources = routes.grouped("resources")

    resources.get(use: index)
      .openAPI(
        tags: "Resources",
        summary: "List resources",
        response: .type([Resource.Public].self),
      )
    resources.grouped(Require.admin).post(use: create)
      .openAPI(
        tags: "Resources",
        summary: "Create resource",
        body: .type(Resource.Create.self),
        response: .type(Resource.Public.self),
        statusCode: 201,
        auth: .bearer(),
      )
    resources.group(":resourceID") { resource in
      resource.get(use: show)
        .openAPI(
          tags: "Resources",
          summary: "Get resource by ID",
          response: .type(Resource.Public.self),
        )
      resource.grouped(Require.admin).patch(use: update)
        .openAPI(
          tags: "Resources",
          summary: "Update resource",
          body: .type(Resource.Update.self),
          response: .type(Resource.Public.self),
          auth: .bearer(),
        )
      resource.grouped(Require.admin).delete(use: delete)
        .openAPI(
          tags: "Resources",
          summary: "Delete resource",
          statusCode: 204,
          auth: .bearer(),
        )
      resource.grouped(Require.admin).post("collect", use: collect)
        .openAPI(
          tags: "Resources",
          summary: "Collect this resource now",
          response: .type(Resource.CollectionDispatch.self),
          statusCode: 202,
          auth: .bearer(),
        )
    }
  }

  @Sendable
  /// Lists all active resources, with the same cross-registry `links` eager load `show` uses.
  ///
  /// Fluent batches an eager load per query, not per row, so this is a fixed handful of extra
  /// queries for the whole list — not N+1 — and it is what lets the dashboard's provenance graph
  /// see links at all, since nothing in the dashboard ever calls `show`.
  ///
  /// `withDeleted: true` on both `hubResource` and `repositoryResource`: same trap
  /// `SyncPatraCatalog.register` documents on its own `.with(\.$resource, withDeleted: true)`.
  /// These are `@OptionalParent` — a card can carry a non-nil `hub_resource_id`/
  /// `repository_resource_id` whose row has since been soft-deleted, and Fluent's default eager
  /// load excludes soft-deleted rows from the query but does NOT treat the resulting miss as "no
  /// parent" the way a genuinely nil id would. It throws `missingParentError` instead. Once any
  /// admin soft-deletes a resource a Patra card points at, every future `GET /resources` (and
  /// `GET /resources/:id`) 500s — including the admin console's own call, which is the one this
  /// endpoint feeds — until someone fixes it at the database layer, since the UI that would let an
  /// admin undo the delete never loads either.
  func index(req: Request) async throws -> [Resource.Public] {
    try await Resource.query(on: req.db)
      .with(\.$patraCards) { card in
        card.with(\.$hubResource, withDeleted: true) { hub in
          hub.with(\.$account)
        }
        card.with(\.$repositoryResource, withDeleted: true) { repository in
          repository.with(\.$account)
        }
      }
      .all()
      .map { $0.toPublic() }
  }

  @Sendable
  /// Creates, immediately collects, and schedules a resource under an existing account.
  func create(req: Request) async throws -> Response {
    let resource = try req.content.decode(Resource.Create.self).toModel()

    guard let account = try await Account.find(resource.$account.id, on: req.db)
    else {
      throw Abort(.badRequest, reason: "Account with ID: \(resource.$account.id), not found.")
    }

    // Capped deliberately below the retention window, leaving headroom for a missed collection.
    resource.collectionIntervalDays = try requireInRange(
      resource.collectionIntervalDays,
      1...account.platform.maxCollectionIntervalDays,
      "collectionIntervalDays",
    )

    try await conflictOnConstraintFailure(
      "A \(resource.type.rawValue) named '\(resource.name)' already exists for this account.",
    ) {
      try await account.$resources.create(resource, on: req.db)
    }

    // Collect now rather than waiting on the sweep, which could be up to an hour away.
    try await req.queues(.metrics).dispatchSync(
      for: resource,
      platform: account.platform,
      logger: req.logger,
    )
    resource.scheduleNextCollection()
    try await resource.save(on: req.db)

    return try await resource.toPublic().encodeResponse(status: .created, for: req)
  }

  @Sendable
  /// Returns one resource by identifier, with the other registries it also exists under, when
  /// its Patra cards recorded any.
  ///
  /// `Resource.find` can't express this: building `Public.links` needs each Patra card's
  /// `hubResource`/`repositoryResource` loaded, and each of those needs its own `account` loaded
  /// to know which platform it belongs to — so `show` is the one place this nested `.with` chain
  /// has to live.
  ///
  /// `withDeleted: true` on both eager loads for the same reason `index` above carries it: an
  /// `@OptionalParent` whose id survives its target's soft delete throws `missingParentError`
  /// rather than resolving to nil, so omitting this turns one soft-deleted resource into a
  /// permanent 500 for every card that ever pointed at it.
  func show(req: Request) async throws -> Resource.Public {
    guard let resourceID = req.parameters.get("resourceID", as: UUID.self) else {
      throw Abort(.notFound)
    }

    let query = Resource.query(on: req.db)
      .filter(\.$id == resourceID)
      .with(\.$patraCards) { card in
        card.with(\.$hubResource, withDeleted: true) { hub in
          hub.with(\.$account)
        }
        card.with(\.$repositoryResource, withDeleted: true) { repository in
          repository.with(\.$account)
        }
      }

    guard let resource = try await query.first() else {
      throw Abort(.notFound)
    }

    return resource.toPublic()
  }

  @Sendable
  /// Updates a resource's own catalog fields, re-validating cadence against its account's
  /// platform the same way `create` does.
  func update(req: Request) async throws -> Resource.Public {
    guard let resource = try await Resource.find(req.parameters.get("resourceID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    let newValues = try req.content.decode(Resource.Update.self)

    if let name = newValues.name {
      resource.name = try requireNonBlank(name, "name").lowercased()
    }
    if let type = newValues.type {
      resource.type = type
    }
    if let collectionIntervalDays = newValues.collectionIntervalDays {
      guard let account = try await Account.find(resource.$account.id, on: req.db)
      else {
        throw Abort(.badRequest, reason: "Account with ID: \(resource.$account.id), not found.")
      }
      resource.collectionIntervalDays = try requireInRange(
        collectionIntervalDays,
        1...account.platform.maxCollectionIntervalDays,
        "collectionIntervalDays",
      )
    }

    try await conflictOnConstraintFailure(
      "A \(resource.type.rawValue) named '\(resource.name)' already exists for this account.",
    ) {
      try await resource.save(on: req.db)
    }

    return resource.toPublic()
  }

  @Sendable
  /// Soft-deletes a resource and its future collection eligibility.
  func delete(req: Request) async throws -> HTTPStatus {
    guard let resource = try await Resource.find(req.parameters.get("resourceID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    try await resource.delete(on: req.db)
    return .noContent
  }

  /// Enqueues a sync for one resource immediately, outside its schedule.
  ///
  /// For the operator who has just repaired a credential or shipped a collector fix and wants to
  /// know whether it worked. Waiting is otherwise the only option, and it is a bad one: a
  /// credential failure re-books an hour out, but every other failure keeps the due date the sweep
  /// already advanced, which can be a full cadence away.
  ///
  /// Dispatched with no retry budget. The scheduled budget spends roughly ten and a half minutes
  /// across its backoff before it reports, which is correct for an unattended sweep riding out a
  /// throttle and useless to someone watching for an answer. A transient blip therefore reads as a
  /// failure here where the sweep would have recovered — the operator clicks again.
  ///
  /// Scheduling state is left alone deliberately. This returns before the job runs, so the only
  /// thing it could do is move `nextCollectionAt` without knowing the outcome, which would push a
  /// broken resource a further cadence out on every attempt to fix it. The redundant collection
  /// that occasionally follows is harmless: watermarks already make a repeated fold safe.
  ///
  /// - Returns: 202 with the dispatch timestamp, which is what lets the caller tell an outcome
  ///   caused by this dispatch from one already in the table.
  /// - Throws: 404 when the resource does not exist, 422 when its platform has no collector.
  @Sendable
  func collect(req: Request) async throws -> Response {
    guard
      let resource = try await Resource.query(on: req.db)
        .filter(\.$id == req.parameters.require("resourceID", as: UUID.self))
        .with(\.$account)
        .first()
    else {
      throw Abort(.notFound)
    }

    let platform = resource.account.platform

    // Refusing beats a 202 here. `dispatchSync` skips these silently, which is right for the
    // sweep and wrong for a request: nothing would be enqueued, no metric or failure would ever
    // appear, and the caller would poll until it timed out with no way to tell why.
    guard platform.isCollectable else {
      throw Abort(
        .unprocessableEntity,
        reason:
          "\(platform.rawValue) resources are catalogued but not collected. There is no collector to run for this platform."
      )
    }

    // Read before the dispatch, never after. The worker can write a metric the instant the job is
    // picked up, and a timestamp taken afterwards could land past it — which would make a
    // successful collection invisible to whoever is polling for it.
    let dispatchedAt = Date()
    let resourceID = try resource.requireID()

    try await req.queues(.metrics).dispatchSync(
      for: resource,
      platform: platform,
      logger: req.logger,
      maxRetryCount: 0,
    )

    req.logger.notice(
      "Collection dispatched on request.",
      metadata: [
        "resource": .string(resourceID.uuidString),
        "platform": .string(platform.rawValue),
      ]
    )

    return try await Resource.CollectionDispatch(
      resourceID: resourceID,
      dispatchedAt: dispatchedAt,
    ).encodeResponse(status: .accepted, for: req)
  }
}
