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
  /// Lists all active resources.
  func index(req: Request) async throws -> [Resource.Public] {
    try await Resource.query(on: req.db).all().map { $0.toPublic() }
  }

  @Sendable
  /// Creates, immediately collects, and schedules a resource under an existing account.
  func create(req: Request) async throws -> Response {
    let resource = try req.content.decode(Resource.Create.self).toModel()

    guard let account = try await Account.find(resource.$account.id, on: req.db)
    else {
      throw Abort(.badRequest, reason: "Account with ID: \(resource.$account.id), not found.")
    }

    // Bounded by the platform's retention window; beyond it, gap days age out unrecoverably.
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
  /// Returns one resource by identifier.
  func show(req: Request) async throws -> Resource.Public {
    guard let resource = try await Resource.find(req.parameters.get("resourceID"), on: req.db)
    else {
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
