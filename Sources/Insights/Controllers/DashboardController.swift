import Vapor
import VaporToOpenAPI

struct DashboardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("dashboard", use: dashboard)
            .excludeFromOpenAPI()
    }

    @Sendable
    func dashboard(req: Request) async throws -> View {
        // Renders the shell only; the chart pulls its data client-side from GET /metrics.
        try await req.view.render("dashboard")
    }
}
