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
  ///
  /// The nested `account` loads carry `withDeleted: true` for the same reason one level down.
  /// `AccountController.delete` requires an account's resources to be deleted first, so "delete
  /// the resources, then the account" is the normal path, and it leaves a card pointing at a
  /// deleted resource whose account is deleted too. A plain load of that account throws the
  /// same `missingParent`.
  func index(req: Request) async throws -> [Resource.Public] {
    try await Resource.query(on: req.db)
      .with(\.$patraCards) { card in
        card.with(\.$hubResource, withDeleted: true) { hub in
          hub.with(\.$account, withDeleted: true)
        }
        card.with(\.$repositoryResource, withDeleted: true) { repository in
          repository.with(\.$account, withDeleted: true)
        }
      }
      .all()
      .map { $0.toPublic() }
  }

  @Sendable
  /// Creates, immediately collects, and schedules a resource under an existing account.
  ///
  /// The resource is inserted already due, so a first collection that cannot be dispatched is
  /// picked up by the next hourly sweep rather than never.
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

    // Due from the moment it exists. The row used to be inserted with no due date and booked only
    // after a successful dispatch, so a dispatch that threw (Valkey unreachable) left it NULL, and
    // the sweep's `<= now` filter never matches NULL: the resource was silently never collected.
    // Inserted due, the worst a failed dispatch can cost is waiting for the next hourly sweep.
    let now = Date()
    resource.nextCollectionAt = now

    try await conflictOnConstraintFailure(
      "A \(resource.type.rawValue) named '\(resource.name)' already exists for this account.",
    ) {
      try await account.$resources.create(resource, on: req.db)
    }

    // Collect now rather than waiting on the sweep, which could be up to an hour away.
    //
    // A dispatch failure is logged, not thrown. The row is already committed and due, so the
    // resource *was* created and will be collected; answering 500 would tell the admin otherwise,
    // and their retry would hit the unique index and get a confusing 409. Only the head start is
    // lost, which is the same trade `CollectDueResources` makes when one dispatch fails.
    do {
      try await req.queues(.metrics).dispatchSync(
        for: resource,
        platform: account.platform,
        logger: req.logger,
      )
    } catch {
      req.logger.error(
        "Could not dispatch the first collection for a new resource; the next sweep will collect it.",
        metadata: [
          "resource": .string(resource.id?.uuidString ?? "unsaved"),
          "error": .string(String(reflecting: error)),
        ]
      )
      return try await resource.toPublic().encodeResponse(status: .created, for: req)
    }

    // The dispatch is the lease, exactly as in the sweep: book the next collection from it, so
    // the sweep does not dispatch a second job while this one is outstanding.
    resource.scheduleNextCollection(from: now)
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
  /// permanent 500 for every card that ever pointed at it. The nested `account` loads carry it
  /// too, as `index` explains.
  func show(req: Request) async throws -> Resource.Public {
    guard let resourceID = req.parameters.get("resourceID", as: UUID.self) else {
      throw Abort(.notFound)
    }

    let query = Resource.query(on: req.db)
      .filter(\.$id == resourceID)
      .with(\.$patraCards) { card in
        card.with(\.$hubResource, withDeleted: true) { hub in
          hub.with(\.$account, withDeleted: true)
        }
        card.with(\.$repositoryResource, withDeleted: true) { repository in
          repository.with(\.$account, withDeleted: true)
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
}
