import Fluent
import Vapor

/// Registers the application's public HTTP, dashboard, and OpenAPI routes.
///
/// - Parameter app: The configured Vapor application whose router receives the endpoints.
/// - Throws: Any error raised while a route collection or OpenAPI document is registered.
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
