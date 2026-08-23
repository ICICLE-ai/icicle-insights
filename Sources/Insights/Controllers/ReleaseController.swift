import Fluent
import Vapor
import VaporToOpenAPI

/// Provides release history reads and internal release mutation handlers.
struct ReleaseController: RouteCollection {
  /// Mounts release routes under `/releases`.
  func boot(routes: any RoutesBuilder) throws {
    let releases = routes.grouped("releases")

    releases.get(use: index)
      .openAPI(
        tags: "Releases",
        summary: "List releases",
        response: .type([Release.Public].self),
      )
    releases.grouped(Require.admin).post(use: create)
      .openAPI(
        tags: "Releases",
        summary: "Create release",
        body: .type(Release.Create.self),
        response: .type(Release.Public.self),
        statusCode: 201,
        auth: .bearer(),
      )
    releases.group(":releaseID") { release in
      release.get(use: show)
        .openAPI(
          tags: "Releases",
          summary: "Get release by ID",
          response: .type(Release.Public.self),
        )
      release.grouped(Require.admin).patch(use: update)
        .openAPI(
          tags: "Releases",
          summary: "Update release",
          body: .type(Release.Update.self),
          response: .type(Release.Public.self),
          auth: .bearer(),
        )
      release.grouped(Require.admin).delete(use: delete)
        .openAPI(
          tags: "Releases",
          summary: "Delete release",
          statusCode: 204,
          auth: .bearer(),
        )
    }
  }

  @Sendable
  /// Lists all recorded releases.
  func index(req: Request) async throws -> [Release.Public] {
    try await Release.query(on: req.db).all().map { $0.toPublic() }
  }

  @Sendable
  /// Creates a validated release for an existing resource.
  func create(req: Request) async throws -> Response {
    let release = try req.content.decode(Release.Create.self).toModel()

    guard let resource = try await Resource.find(release.$resource.id, on: req.db)
    else {
      throw Abort(.badRequest, reason: "Resource with ID: \(release.$resource.id), not found.")
    }
    try await resource.$releases.create(release, on: req.db)

    return try await release.toPublic().encodeResponse(status: .created, for: req)
  }

  @Sendable
  /// Returns one release by identifier.
  func show(req: Request) async throws -> Release.Public {
    guard let release = try await Release.find(req.parameters.get("releaseID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    return release.toPublic()
  }

  @Sendable
  /// Corrects a release's version identifier or release month.
  func update(req: Request) async throws -> Release.Public {
    guard let release = try await Release.find(req.parameters.get("releaseID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    let newValues = try req.content.decode(Release.Update.self)

    if let version = newValues.version {
      release.version = try requireNonBlank(version, "version")
    }

    switch (newValues.month, newValues.year) {
    case (nil, nil):
      break
    case (.some(let month), .some(let year)):
      release.releasedAt = try requireCalendarDate(
        year: requireInRange(year, supportedYears, "year"),
        month: requireInRange(month, 1...12, "month"),
        "releasedAt",
      )
    default:
      throw Abort(.badRequest, reason: "'month' and 'year' must be supplied together.")
    }

    try await release.save(on: req.db)
    return release.toPublic()
  }

  @Sendable
  /// Permanently deletes one release record.
  func delete(req: Request) async throws -> HTTPStatus {
    guard let release = try await Release.find(req.parameters.get("releaseID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    try await release.delete(on: req.db)
    return .noContent
  }
}
