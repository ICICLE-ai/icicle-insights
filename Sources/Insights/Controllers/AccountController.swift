import Fluent
import Vapor
import VaporToOpenAPI

struct AccountController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let accounts = routes.grouped("accounts")

        accounts.get(use: index)
            .openAPI(
                tags: "Accounts",
                summary: "List accounts",
                response: .type([Account.Public].self),
            )
        // Mutating routes stay disabled until auth middleware protects them. The handlers
        // below are kept intact so re-enabling is just uncommenting the registrations.
        // accounts.post(use: create)
        //     .openAPI(
        //         tags: "Accounts",
        //         summary: "Create account",
        //         body: .type(Account.Create.self),
        //         response: .type(Account.Public.self),
        //         statusCode: 201,
        //     )
        accounts.group(":accountID") { account in
            account.get(use: show)
                .openAPI(
                    tags: "Accounts",
                    summary: "Get account by ID",
                    response: .type(Account.Public.self),
                )
            // account.patch(use: update)
            //     .openAPI(
            //         tags: "Accounts",
            //         summary: "Update account followers",
            //         body: .type(Account.Update.self),
            //         response: .type(Account.Public.self),
            //     )
            // account.delete(use: delete)
            //     .openAPI(
            //         tags: "Accounts",
            //         summary: "Delete account",
            //         statusCode: 204,
            //     )
        }
    }

    @Sendable
    func index(req: Request) async throws -> [Account.Public] {
        try await Account.query(on: req.db).all().map { $0.toPublic() }
    }

    @Sendable
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
    func delete(req: Request) async throws -> HTTPStatus {
        guard let account = try await Account.find(req.parameters.get("accountID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await account.delete(on: req.db)
        return .noContent
    }

}
