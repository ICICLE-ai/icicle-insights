import Fluent
import Vapor
import VaporToOpenAPI

/// Serves account catalog endpoints and account-level mutations that are currently enabled.
struct AccountController: RouteCollection {
  /// Mounts account routes under `/accounts`.
  func boot(routes: any RoutesBuilder) throws {
    let accounts = routes.grouped("accounts")

    accounts.get(use: index)
      .openAPI(
        tags: "Accounts",
        summary: "List accounts",
        response: .type([Account.Public].self),
      )
    accounts.grouped(Require.admin).post(use: create)
      .openAPI(
        tags: "Accounts",
        summary: "Create account",
        body: .type(Account.Create.self),
        response: .type(Account.Public.self),
        statusCode: 201,
        auth: .bearer(),
      )
    accounts.group(":accountID") { account in
      account.get(use: show)
        .openAPI(
          tags: "Accounts",
          summary: "Get account by ID",
          response: .type(Account.Public.self),
        )
      account.grouped(Require.admin).patch(use: update)
        .openAPI(
          tags: "Accounts",
          summary: "Update account followers",
          body: .type(Account.Update.self),
          response: .type(Account.Public.self),
          auth: .bearer(),
        )
      account.grouped(Require.admin).delete(use: delete)
        .openAPI(
          tags: "Accounts",
          summary: "Delete account",
          statusCode: 204,
          auth: .bearer(),
        )
    }
  }

  @Sendable
  /// Lists every account visible to the application.
  func index(req: Request) async throws -> [Account.Public] {
    try await Account.query(on: req.db).all().map { $0.toPublic() }
  }

  @Sendable
  /// Creates an account after validating uniqueness and request fields.
  func create(req: Request) async throws -> Response {
    let account = try req.content.decode(Account.Create.self).toModel()

    try await conflictOnConstraintFailure(
      "An account named '\(account.name)' already exists for platform '\(account.platform.rawValue)'.",
    ) {
      try await account.save(on: req.db)
    }

    return try await account.toPublic().encodeResponse(status: .created, for: req)
  }

  @Sendable
  /// Returns one account with its resources and Vault metadata loaded.
  func show(req: Request) async throws -> Account.Public {
    guard let account = try await Account.find(req.parameters.get("accountID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    try await account.$resources.load(on: req.db)
    try await account.$vault.load(on: req.db)
    return account.toPublic()
  }

  @Sendable
  /// Updates mutable account statistics supplied by the client.
  func update(req: Request) async throws -> Account.Public {
    guard let account = try await Account.find(req.parameters.get("accountID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    let newValues = try req.content.decode(Account.Update.self)

    if let followers = newValues.followers {
      account.followers = try requireNonNegative(followers, "followers")
    }

    try await account.save(on: req.db)
    return account.toPublic()
  }

  @Sendable
  /// Soft-deletes an account that no longer owns anything, and returns an empty success response.
  ///
  /// Refused with 409 while the account still has an active resource or a Vault credential. A
  /// soft-deleted account leaves its resources active and due, and every place that eager-loads a
  /// resource's account then finds no parent: Fluent's default load excludes the deleted row and
  /// throws `missingParent` rather than answering nil. `CollectDueResources` loads the whole due
  /// set in one query, so before this guard a single such resource failed every hourly sweep and
  /// nothing was collected for anyone.
  ///
  /// Mirrors the admin console's own guard (`account-management.ts`, `canDelete`/`deleteTitle`),
  /// in the same order and with the same wording, so a caller that skips the console gets the
  /// same answer. The console guard alone was not enough: it is advisory, and the API is public.
  ///
  /// Check-then-delete, not a lock: a resource created between the count and the delete still
  /// leaves an orphan. That window is milliseconds on an admin-only route, and the sweep and the
  /// sync jobs now tolerate an orphan rather than failing on it, so this guard prevents the
  /// common case and the collectors absorb the rare one.
  func delete(req: Request) async throws -> HTTPStatus {
    guard let account = try await Account.find(req.parameters.get("accountID"), on: req.db)
    else {
      throw Abort(.notFound)
    }

    let accountID = try account.requireID()

    // Fluent's default scope already excludes soft-deleted resources, which is the point: a
    // resource an admin has deleted no longer blocks deleting its account.
    let resources = try await Resource.query(on: req.db)
      .filter(\.$account.$id == accountID)
      .count()
    guard resources == 0 else {
      throw Abort(
        .conflict,
        reason:
          "This account still has \(resources) active resource\(resources == 1 ? "" : "s"). "
          + "Delete this account's resources first.",
      )
    }

    // `vaults` has no soft delete, so any row is a live credential reference. Deleting the
    // account around it would strand the Tapis secret with nothing in the console to rotate or
    // remove it from.
    let hasVault =
      try await Vault.query(on: req.db)
      .filter(\.$account.$id == accountID)
      .first() != nil
    guard !hasVault else {
      throw Abort(.conflict, reason: "Delete this account's Vault credential first.")
    }

    try await account.delete(on: req.db)
    return .noContent
  }

}
