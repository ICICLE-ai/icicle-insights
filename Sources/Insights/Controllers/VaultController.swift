import Fluent
import Vapor
import VaporToOpenAPI

struct VaultController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let vaults = routes.grouped("vaults")

        vaults.get(use: index)
            .openAPI(
                tags: "Vaults",
                summary: "List vaults",
                response: .type([Vault.Public].self)
            )
        // Mutating routes stay disabled until auth middleware protects them. The handlers
        // below are kept intact so re-enabling is just uncommenting the registrations.
        // vaults.post(use: create)
        //     .openAPI(
        //         tags: "Vaults",
        //         summary: "Create vault",
        //         body: .type(Vault.Create.self),
        //         response: .type(Vault.Public.self),
        //         statusCode: 201
        //     )
        vaults.group(":vaultID") { vault in
            vault.get(use: show)
                .openAPI(
                    tags: "Vaults",
                    summary: "Get vault by ID",
                    response: .type(Vault.Public.self)
                )
            // vault.patch(use: update)
            //     .openAPI(
            //         tags: "Vaults",
            //         summary: "Update token in vault",
            //         body: .type(Vault.Update.self),
            //         response: .type(Vault.Public.self)
            //     )
            // vault.delete(use: delete)
            //     .openAPI(
            //         tags: "Vaults",
            //         summary: "Delete vault",
            //         statusCode: 204
            //     )
        }
    }

    @Sendable
    func index(req: Request) async throws -> [Vault.Public] {
        try await Vault.query(on: req.db).all().map { $0.toPublic() }
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let payload = try req.content.decode(Vault.Create.self)
        let vault = try payload.toModel()

        guard let account = try await Account.find(vault.$account.id, on: req.db)
        else {
            throw Abort(.badRequest, reason: "Account with ID: \(vault.$account.id), not found.")
        }

        try await conflictOnConstraintFailure(
            "A vault named '\(vault.name)' already exists for this account.",
        ) {
            try await account.$vault.create(vault, on: req.db)
        }

        // TODO: Save token in vault

        return try await vault.toPublic().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func show(req: Request) async throws -> Vault.Public {
        guard let vault = try await Vault.find(req.parameters.get("vaultID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        return vault.toPublic()
    }

    @Sendable
    func update(req: Request) async throws -> Vault.Public {
        guard let vault = try await Vault.find(req.parameters.get("vaultID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        let newValues = try req.content.decode(Vault.Update.self)

        // Validated here even though the token is not persisted yet — see the TODO below.
        _ = try requireNonBlank(newValues.token, "token")

        vault.expiresAt = try newValues.expires.toDate()

        try await vault.save(on: req.db)

        // TODO: Send token to vault

        return vault.toPublic()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let vault = try await Vault.find(req.parameters.get("vaultID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await vault.delete(on: req.db)
        return .noContent
    }
}
