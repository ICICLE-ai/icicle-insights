import Vapor

import struct Foundation.UUID

/// Makes the per-request correlation ID usable by callers and by anything that outlives the
/// request.
///
/// Vapor already resolves an ID for every request — the inbound `X-Request-Id` header if one is
/// present, otherwise a fresh UUID — and stamps it into `req.logger` metadata. Two things it does
/// not do, which is all this middleware adds:
///
/// 1. **Echo it back.** Without a response header the caller never learns the ID, so a frontend
///    bug report cannot name the request it is about.
/// 2. **Constrain it.** The inbound header is attacker-controlled and copied verbatim into log
///    metadata. A value carrying newlines can forge log lines in any line-oriented sink, and an
///    unbounded one bloats every record for the request. Anything implausible is replaced.
struct RequestIDMiddleware: AsyncMiddleware {
  /// Longer than a UUID with room for a caller's own prefix, short enough to bound the damage.
  static let maxLength = 64

  /// Header used in both directions. Matches the name Vapor reads on the way in.
  static let headerName = "X-Request-ID"

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    let id = Self.sanitize(request.id)

    // Only rewrite when the caller's value was rejected. Vapor has already stamped `request.id`
    // into the logger, so in the overwhelmingly common case there is nothing to do here.
    if id != request.id {
      request.logger[metadataKey: "request-id"] = .string(id)
      request.logger.debug("Inbound request ID was rejected; substituted a generated one.")
    }

    request.storage[RequestIDKey.self] = id

    let response = try await next.respond(to: request)
    response.headers.replaceOrAdd(name: Self.headerName, value: id)
    return response
  }

  /// Returns `id` when it is safe to log and echo, or a fresh UUID when it is not.
  ///
  /// Deliberately a strict allowlist rather than an escape or a strip. A sanitized-but-altered ID
  /// still correlates to nothing on the caller's side, so there is no value in salvaging a
  /// malformed one — and an allowlist cannot be defeated by an encoding nobody anticipated.
  static func sanitize(_ id: String) -> String {
    let acceptable = id.allSatisfy { character in
      character.isASCII
        && (character.isLetter || character.isNumber || character == "-"
          || character == "_")
    }

    guard acceptable, !id.isEmpty, id.count <= maxLength else {
      return UUID().uuidString
    }

    return id
  }
}

private struct RequestIDKey: StorageKey {
  typealias Value = String
}

extension Request {
  /// The correlation ID for this request, validated and identical to the `X-Request-ID` response
  /// header the caller receives.
  ///
  /// Prefer this over `id` when the value will be persisted, sent to Slack, or written into a job
  /// payload: `id` is whatever the caller sent, while this has been through ``
  /// RequestIDMiddleware/sanitize(_:)``.
  var requestID: String {
    storage[RequestIDKey.self] ?? id
  }
}
