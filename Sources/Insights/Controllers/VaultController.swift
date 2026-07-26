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
        vaults.post(use: create)
            .openAPI(
                tags: "Vaults",
                summary: "Create vault",
                body: .type(Vault.Create.self),
                response: .type(Vault.Public.self),
                statusCode: 201
            )
        vaults.group(":vaultID") { vault in
            vault.get(use: show)
                .openAPI(
                    tags: "Vaults",
                    summary: "Get vault by ID",
                    response: .type(Vault.Public.self)
                )
            vault.patch(use: update)
                .openAPI(
                    tags: "Vaults",
                    summary: "Update token in vault",
                    body: .type(Vault.Update.self),
                    response: .type(Vault.Public.self)
                )
            vault.delete(use: delete)
                .openAPI(
                    tags: "Vaults",
                    summary: "Delete vault",
                    statusCode: 204
                )
        }
    }

    @Sendable
    func index(req: Request) async throws -> [Vault.Public] {
        try await Vault.query(on: req.db).all().map { $0.toPublic() }
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let payload = try req.content.decode(Vault.Create.self)
        let vault = payload.toModel()

        guard let account = try await Account.find(vault.$account.id, on: req.db)
        else {
            throw Abort(.badRequest, reason: "Account with ID: \(vault.$account.id), not found.")
        }

        vault.name = "\(account.name)-\(account.platform)-api-token"

        // Row and secret must land together: a committed row whose secret failed to write is
        // metadata pointing at nothing.
        try await req.db.transaction { db in
            try await account.$vault.create(vault, on: db)
            try await req.application.tapis.vaults.writeSecret(named: vault.name, secret: payload.token)
        }

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

        // Convert expiration date to Date
        var expirationDate = DateComponents()
        expirationDate.day = newValues.expires.day
        expirationDate.month = newValues.expires.month
        expirationDate.year = newValues.expires.year

        vault.expiresAt = Calendar(identifier: .gregorian).date(from: expirationDate)

        // Rotate the token and record the new expiry together, so a failure on either side
        // never leaves the two disagreeing.
        try await req.db.transaction { db in
            try await vault.save(on: db)
            try await req.application.tapis.vaults.writeSecret(named: vault.name, secret: newValues.token)
        }

        return vault.toPublic()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let vault = try await Vault.find(req.parameters.get("vaultID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Soft delete our metadata and destroy the token on the Vault platform together: a
        // failed destroy must not leave the row deleted with the secret still live.
        try await req.db.transaction { db in
            try await vault.delete(on: db)
            try await req.application.tapis.vaults.destroySecret(named: vault.name)
        }

        return .noContent
    }
}
