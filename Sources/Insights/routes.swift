import Fluent
import Vapor

/// Registers the application's public HTTP, dashboard, and OpenAPI routes.
///
/// - Parameter app: The configured Vapor application whose router receives the endpoints.
/// - Throws: Any error raised while a route collection or OpenAPI document is registered.
func routes(_ app: Application) throws {
  app.get { req async throws in
    try await req.view.render("dashboard", ["title": "ICICLE Insights"])
  }

  // Both authenticators run on every `/api` request and neither rejects anything: each logs in
  // its own identity if the bearer value is one it recognizes, and returns quietly otherwise.
  // That is what keeps reads open to anonymous callers while `Require` — attached per route
  // inside each controller — decides who may write.
  // Per-IP ceiling ahead of the authenticators: it is the only identity available before
  // anything has been verified, and it is what stops an unauthenticated flood.
  let api =
    app
    .grouped("api")
    .grouped(RateLimiter.perAddress)
    .grouped(TapisAuthenticator(), ServiceTokenAuthenticator())

  try api.register(collection: AccountController())
  try api.register(collection: VaultController())
  try api.register(collection: ResourceController())
  try api.register(collection: ReleaseController())
  try api.register(collection: MetricController())
  try api.register(collection: ServiceTokenController())
  try api.register(collection: AdminController())

  try app.register(collection: DashboardController())

  // Outside `api`, so orchestrator probes are neither rate limited nor made to look like API
  // traffic in the logs.
  try app.register(collection: HealthController())

  try registerOpenAPI(app)
}
