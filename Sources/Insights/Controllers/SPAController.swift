import Foundation
import Vapor
import VaporToOpenAPI

/// Serves the Angular entry point for the root and client-side routes.
///
/// Concrete API, documentation, and probe routes continue to win over the catchall in Vapor's
/// trie. The explicit prefix check is still important for *unknown* API paths: returning the SPA
/// with status 200 for `/api/misspelled` turns a useful JSON 404 into an HTML parse error in the
/// client. Missing file-like paths are rejected for the same reason, so a deleted hashed chunk
/// cannot be answered with `index.html`.
struct SPAController: RouteCollection {
  private static let reservedRoots: Set<String> = [
    "api", "docs", "health", "openapi.json", "ready",
  ]

  func boot(routes: any RoutesBuilder) throws {
    routes.get(use: index).excludeFromOpenAPI()

    // Keep historical bookmarks working without preserving any of the Leaf dashboard itself.
    routes.get("dashboard") { request in request.redirect(to: "/", redirectType: .permanent) }
      .excludeFromOpenAPI()

    routes.get(.catchall, use: fallback).excludeFromOpenAPI()
  }

  @Sendable
  func index(request: Request) async throws -> Response {
    try await serveIndex(request: request)
  }

  @Sendable
  func fallback(request: Request) async throws -> Response {
    let components = request.parameters.getCatchall()
    guard Self.shouldServeIndex(for: components) else {
      throw Abort(.notFound)
    }
    return try await serveIndex(request: request)
  }

  /// Pure route classification, separated so API/file fallthrough behavior is easy to test.
  static func shouldServeIndex(for components: [String]) -> Bool {
    guard
      let first = components.first?.lowercased(),
      !reservedRoots.contains(first),
      let last = components.last,
      !last.contains(".")
    else {
      return false
    }

    return true
  }

  private func serveIndex(request: Request) async throws -> Response {
    let path = request.application.directory.publicDirectory + "index.html"
    guard FileManager.default.fileExists(atPath: path) else {
      request.logger.critical(
        "Angular entry point is missing from Public.",
        metadata: ["path": .string(path)]
      )
      throw Abort(
        .serviceUnavailable,
        reason: "The web application has not been built into the server image."
      )
    }

    let response = try await request.fileio.asyncStreamFile(at: path)
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
    return response
  }
}
