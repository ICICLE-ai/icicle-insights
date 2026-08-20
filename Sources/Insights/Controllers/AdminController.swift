import Fluent
import Vapor
import VaporToOpenAPI

/// Manages who may administer Insights, so granting access stops requiring a redeploy.
///
/// Admin-only, necessarily — this is the route that decides who gets to use it. The root admin
/// from `ROOT_ADMIN_USERNAME` is listed but cannot be removed here: it is the break-glass path
/// that makes an accidental self-lockout recoverable.
struct AdminController: RouteCollection {
  /// Mounts admin management under `/admins`.
  func boot(routes: any RoutesBuilder) throws {
    let admins = routes.grouped("admins").grouped(Require.admin)

    admins.get(use: index)
      .openAPI(
        tags: "Admins",
        summary: "List admins",
        response: .type([Admin.Public].self),
        auth: .bearer()
      )
    admins.post(use: create)
      .openAPI(
        tags: "Admins",
        summary: "Grant admin access",
        body: .type(Admin.Create.self),
        response: .type(Admin.Public.self),
        statusCode: 201,
        auth: .bearer()
      )
    admins.delete(":adminID", use: delete)
      .openAPI(
        tags: "Admins",
        summary: "Revoke admin access",
        statusCode: 204,
        auth: .bearer()
      )
  }

  @Sendable
  /// Lists the root admin followed by everyone granted access since.
  func index(req: Request) async throws -> [Admin.Public] {
    let stored = try await Admin.query(on: req.db).sort(\.$createdAt).all().map { $0.toPublic() }

    // Synthesised rather than stored, so the listing reflects who can actually get in — the
    // root admin holds access whether or not the table has ever been written to.
    let root = Admin.Public(
      id: nil,
      username: req.application.rootAdmin,
      addedBy: "ROOT_ADMIN_USERNAME",
      createdAt: nil,
      isRoot: true,
    )

    return [root] + stored
  }

  @Sendable
  /// Grants administrative access to a Tapis username.
  func create(req: Request) async throws -> Response {
    let granter = try req.auth.require(TapisUser.self)
    let admin = try req.content.decode(Admin.Create.self).toModel(addedBy: granter.username)

    guard admin.username != req.application.rootAdmin else {
      throw Abort(.conflict, reason: "'\(admin.username)' is already the root admin.")
    }

    let existing = try await Admin.query(on: req.db)
      .filter(\.$username == admin.username)
      .first()

    guard existing == nil else {
      throw Abort(.conflict, reason: "'\(admin.username)' is already an admin.")
    }

    try await admin.create(on: req.db)

    return try await admin.toPublic().encodeResponse(status: .created, for: req)
  }

  @Sendable
  /// Revokes access. Takes effect on that person's next request — admin status is resolved per
  /// request during authentication, not cached.
  func delete(req: Request) async throws -> HTTPStatus {
    guard let admin = try await Admin.find(req.parameters.get("adminID"), on: req.db) else {
      throw Abort(.notFound)
    }

    // Cannot happen through `create`, but a hand-written row could name the root admin, and
    // deleting it would imply an access change that never actually takes effect.
    guard admin.username != req.application.rootAdmin else {
      throw Abort(.forbidden, reason: "The root admin cannot be removed through the API.")
    }

    try await admin.delete(on: req.db)

    return .noContent
  }
}
