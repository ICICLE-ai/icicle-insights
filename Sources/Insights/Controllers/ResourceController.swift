import Fluent
import Vapor
import VaporToOpenAPI

struct ResourceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let resources = routes.grouped("resources")

        resources.get(use: index)
            .openAPI(
                tags: "Resources",
                summary: "List resources",
                response: .type([Resource.Public].self),
            )
        // Mutating routes stay disabled until auth middleware protects them. The handlers
        // below are kept intact so re-enabling is just uncommenting the registrations.
        // resources.post(use: create)
        //     .openAPI(
        //         tags: "Resources",
        //         summary: "Create resource",
        //         body: .type(Resource.Create.self),
        //         response: .type(Resource.Public.self),
        //         statusCode: 201,
        //     )
        resources.group(":resourceID") { resource in
            resource.get(use: show)
                .openAPI(
                    tags: "Resources",
                    summary: "Get resource by ID",
                    response: .type(Resource.Public.self),
                )
            // resource.delete(use: delete)
            //     .openAPI(
            //         tags: "Resources",
            //         summary: "Delete resource",
            //         statusCode: 204,
            //     )
        }
    }

    @Sendable
    func index(req: Request) async throws -> [Resource.Public] {
        try await Resource.query(on: req.db).all().map { $0.toPublic() }
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let resource = try req.content.decode(Resource.Create.self).toModel()

        guard let account = try await Account.find(resource.$account.id, on: req.db)
        else {
            throw Abort(.badRequest, reason: "Account with ID: \(resource.$account.id), not found.")
        }

        try await conflictOnConstraintFailure(
            "A \(resource.type.rawValue) named '\(resource.name)' already exists for this account.",
        ) {
            try await account.$resources.create(resource, on: req.db)
        }

        return try await resource.toPublic().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func show(req: Request) async throws -> Resource.Public {
        guard let resource = try await Resource.find(req.parameters.get("resourceID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        return resource.toPublic()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let resource = try await Resource.find(req.parameters.get("resourceID"), on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await resource.delete(on: req.db)
        return .noContent
    }
}
