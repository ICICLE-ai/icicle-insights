import Vapor

/// Applies cache policy by artifact identity after the response has been produced.
///
/// Angular content-hashes production JavaScript and CSS names, so those files are safe to cache
/// for a year: a content change creates a new URL. The entry point must be revalidated on every
/// navigation because it is the mutable map from a deployment to those immutable filenames.
struct StaticAssetCacheMiddleware: AsyncMiddleware {
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    let response = try await next.respond(to: request)

    guard response.status == .ok else { return response }

    if Self.isIndexRequest(path: request.url.path, response: response) {
      response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
    } else if Self.isHashedAssetPath(request.url.path) {
      response.headers.replaceOrAdd(
        name: .cacheControl,
        value: "public, max-age=31536000, immutable"
      )
    }

    return response
  }

  static func isHashedAssetPath(_ path: String) -> Bool {
    let filename = path.split(separator: "/").last.map(String.init) ?? ""
    guard
      let extensionSeparator = filename.lastIndex(of: "."),
      let hashSeparator = filename[..<extensionSeparator].firstIndex(of: "-")
    else {
      return false
    }

    let fileExtension = filename[filename.index(after: extensionSeparator)...].lowercased()
    let cacheableExtensions: Set<String> = [
      "avif", "css", "js", "map", "mjs", "png", "svg", "ttf", "webp", "woff", "woff2",
    ]
    guard cacheableExtensions.contains(fileExtension) else { return false }

    let hash = filename[filename.index(after: hashSeparator)..<extensionSeparator]
    return hash.count >= 8
      && hash.allSatisfy { character in
        character.isASCII
          && (character.isLetter || character.isNumber || character == "-" || character == "_")
      }
  }

  private static func isIndexRequest(path: String, response: Response) -> Bool {
    if path == "/" || path.hasSuffix("/index.html") {
      return true
    }

    // Deep client-side routes have no file extension and are served the same index entry point.
    let finalComponent = path.split(separator: "/").last.map(String.init) ?? ""
    return !finalComponent.contains(".")
      && response.headers.contentType?.type == "text"
      && response.headers.contentType?.subType == "html"
  }
}
