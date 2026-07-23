import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get { req async throws in
        try await req.view.render("index", ["title": "Hello Vapor!"])
    }

    app.get("hello") { _ async -> String in
        "Hello, world!"
    }

    try app.register(collection: AccountController())
    try app.register(collection: VaultController())
    try app.register(collection: ResourceController())
    try app.register(collection: ReleaseController())
    try app.register(collection: MetricController())

    try app.register(collection: DashboardController())

    try registerOpenAPI(app)
}
