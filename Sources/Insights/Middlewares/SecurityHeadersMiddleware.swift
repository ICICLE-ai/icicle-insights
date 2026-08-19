import Vapor

/// Stamps the response headers that do not depend on what the frontend looks like.
///
/// Registered `at: .beginning`, ahead of `ErrorMiddleware`. Response headers are applied on the
/// way back out, so a middleware added later never sees an error response — and an unprotected
/// 500 is exactly the page worth protecting.
///
/// The Content-Security-Policy emitted here covers `frame-ancestors` and nothing else. A full
/// policy needs the Angular bundle's asset origins settled, and a wrong `script-src` breaks the
/// app rather than degrading it. `frame-ancestors` does not depend on any of that, which is why
/// it ships ahead of the rest.
struct SecurityHeadersMiddleware: AsyncMiddleware {
  /// Whether to advertise HSTS. Off outside production, where the dev server is plain HTTP and
  /// a browser that pins `localhost` to HTTPS is unpleasant to un-pin.
  let includeHSTS: Bool

  /// Origins permitted to embed this site in a frame. Empty forbids framing entirely.
  let frameAncestors: [String]

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    let response = try await next.respond(to: request)

    // Stop browsers from second-guessing Content-Type. Without it, a JSON response an attacker
    // influences can be coaxed into executing as script.
    response.headers.replaceOrAdd(name: .xContentTypeOptions, value: "nosniff")

    // Send the origin, not the full path, to third parties. Resource UUIDs live in our paths.
    response.headers.replaceOrAdd(
      name: "Referrer-Policy", value: "strict-origin-when-cross-origin")

    applyFramePolicy(to: response)

    if includeHSTS {
      response.headers.replaceOrAdd(
        name: .strictTransportSecurity, value: "max-age=31536000; includeSubDomains")
    }

    return response
  }

  /// Emits the framing rules, as CSP always and as `X-Frame-Options` only when it can express the
  /// same thing.
  ///
  /// `X-Frame-Options` has no allowlist form — its `ALLOW-FROM` variant was never widely
  /// implemented and is obsolete — so once any origin is permitted the header can only be wrong.
  /// It is therefore omitted rather than downgraded: CSP `frame-ancestors` supersedes it in every
  /// browser that understands both, and browsers that understand neither were never protected.
  private func applyFramePolicy(to response: Response) {
    guard !frameAncestors.isEmpty else {
      response.headers.replaceOrAdd(name: .xFrameOptions, value: "DENY")
      response.headers.replaceOrAdd(
        name: .contentSecurityPolicy, value: "frame-ancestors 'none'")
      return
    }

    let sources = (["'self'"] + frameAncestors).joined(separator: " ")
    response.headers.replaceOrAdd(
      name: .contentSecurityPolicy, value: "frame-ancestors \(sources)")
  }
}

extension SecurityHeadersMiddleware {
  /// Reads the framing allowlist from `FRAME_ANCESTORS`, a comma-separated list of origins.
  ///
  /// Unset or empty denies framing outright, which is the correct default for a standalone
  /// deployment and preserves the behavior this service shipped with. Setting it is how the
  /// dashboard becomes embeddable — a deploy-time change rather than a code change.
  ///
  /// Values are checked against the shape CSP accepts, because a stray comma or a pasted URL path
  /// would otherwise produce a policy the browser rejects wholesale — which fails *open* on
  /// framing, the opposite of what setting this is meant to achieve.
  static func frameAncestorsFromEnvironment(logger: Logger) -> [String] {
    guard let raw = Environment.get("FRAME_ANCESTORS") else { return [] }

    let candidates =
      raw.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    var accepted: [String] = []

    for candidate in candidates {
      guard isValidFrameAncestor(candidate) else {
        logger.warning(
          "Ignoring malformed FRAME_ANCESTORS entry.",
          metadata: ["origin": .string(candidate)]
        )
        continue
      }
      accepted.append(candidate)
    }

    return accepted
  }

  /// Whether a value is a serialized origin CSP will accept.
  ///
  /// Requires a scheme and rejects anything carrying a path, query, fragment, or whitespace —
  /// `frame-ancestors` matches origins, so `https://example.org/app` is a configuration mistake
  /// rather than a narrower rule.
  private static func isValidFrameAncestor(_ value: String) -> Bool {
    guard value.hasPrefix("https://") || value.hasPrefix("http://") else { return false }

    let remainder =
      value
      .replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")

    guard !remainder.isEmpty else { return false }

    return !remainder.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ";" })
      && !remainder.contains(where: \.isWhitespace)
  }
}
