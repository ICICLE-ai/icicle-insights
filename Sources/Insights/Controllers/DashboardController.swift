import Vapor
import VaporToOpenAPI

/// Keeps the historical `/dashboard` URL working.
///
/// The dashboard itself is rendered at the root by `routes(_:)`. This exists only so links and
/// bookmarks predating that move do not 404.
struct DashboardController: RouteCollection {
  /// Mounts the legacy redirect.
  func boot(routes: any RoutesBuilder) throws {
    routes.get("dashboard") { req in
      req.redirect(to: "/")
    }
    .excludeFromOpenAPI()
  }
}
