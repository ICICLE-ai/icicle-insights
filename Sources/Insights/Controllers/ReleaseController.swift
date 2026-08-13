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
    // Mutating routes stay disabled until auth middleware protects them. The handlers
    // below are kept intact so re-enabling is just uncommenting the registrations.
    // releases.post(use: create)
    //     .openAPI(
    //         tags: "Releases",
    //         summary: "Create release",
    //         body: .type(Release.Create.self),
    //         response: .type(Release.Public.self),
    //         statusCode: 201,
    //     )
    releases.group(":releaseID") { release in
      release.get(use: show)
        .openAPI(
          tags: "Releases",
          summary: "Get release by ID",
          response: .type(Release.Public.self),
        )
      // release.delete(use: delete)
      //     .openAPI(
      //         tags: "Releases",
      //         summary: "Delete release",
      //         statusCode: 204,
      //     )
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
