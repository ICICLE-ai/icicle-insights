import NIOCore
import Redis
import Vapor

/// A fixed-window request limit backed by Redis.
///
/// Redis rather than an in-process counter because the API runs more than one pod: an in-memory
/// window would grant the full quota independently on each, so the effective limit would be the
/// configured one multiplied by however many replicas happen to be running. This reuses the
/// Valkey instance queues already depend on.
///
/// **Fails open.** Any Redis error is logged and the request proceeds. A limiter that takes the
/// whole API down when its counter store hiccups causes more harm than the abuse it prevents.
struct RateLimiter: AsyncMiddleware {
  /// How a request is attributed to a caller.
  enum Scope: Sendable {
    /// Per client IP. The only identity available before authentication.
    case clientAddress

    /// Per webhook token. Preferred where it applies: the token is what actually runs away, and
    /// several deployed services may share one egress address.
    case serviceToken
  }

  let scope: Scope
  let limit: Int
  let window: TimeAmount
  /// Distinguishes counters when more than one limiter is in the chain.
  let name: String

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    guard let identity = identity(for: request) else {
      // Nothing to attribute this to — an unauthenticated call on a token-scoped limiter, or a
      // request with no remote address. Let the route's own guard reject it.
      return try await next.respond(to: request)
    }

    let key = RedisKey("ratelimit:\(name):\(identity)")
    let count: Int

    do {
      count = try await request.redis.increment(key).get()

      // Only the first request in a window sets the expiry; doing it every time would slide the
      // window forward forever and the limit would never reset under sustained load.
      if count == 1 {
        _ = try await request.redis.expire(key, after: window)
      }
    } catch {
      request.logger.warning(
        "Rate limit counter unavailable; allowing request.",
        metadata: ["error": .string("\(error)")]
      )
      return try await next.respond(to: request)
    }

    guard count <= limit else {
      let seconds = Int(window.nanoseconds / 1_000_000_000)
      throw Abort(
        .tooManyRequests,
        headers: ["Retry-After": "\(seconds)"],
        reason: "Rate limit exceeded. Try again in \(seconds) seconds."
      )
    }

    return try await next.respond(to: request)
  }

  /// Resolves the counter key, or nil when this request cannot be attributed.
  private func identity(for request: Request) -> String? {
    switch scope {
    case .clientAddress:
      Self.clientAddress(headers: request.headers, remoteAddress: request.remoteAddress)
    case .serviceToken:
      request.auth.get(ServiceClient.self).map { $0.jti.uuidString }
    }
  }

  /// The address to count a request against: the rightmost `X-Forwarded-For` entry when it is a
  /// valid IP, otherwise the socket's remote address.
  ///
  /// Vapor's `Request.peerAddress` was the wrong source, in two opposite ways. It trusts a
  /// `Forwarded` header first, which any client can send. Then it parses the *whole* first
  /// `X-Forwarded-For` line as one address. Behind an ingress that appends, a client that sends
  /// its own header arrives as `spoofed, real`; that fails to parse, and `peerAddress` falls back
  /// to the socket, which is the ingress. Every such visitor then shared one 300-a-minute bucket.
  /// Without an appending proxy the header is taken as-is, so a client could pick its own key and
  /// never be limited at all.
  ///
  /// The rightmost entry is the one the nearest proxy appended: the address that proxy actually
  /// saw. Everything to its left arrived from the client and proves nothing. That assumes exactly
  /// one appending proxy in front of the API, which is the ingress; a second hop would make the
  /// rightmost entry that hop's address. `Forwarded` is ignored for the same reason the left
  /// entries are: nothing in this deployment writes it, so any value came from the client.
  ///
  /// Several `X-Forwarded-For` lines are one list in arrival order, as RFC 9110 defines for a
  /// repeated comma-separated field, so they are joined before the rightmost is taken. A
  /// rightmost entry that is not an IP falls back to the socket rather than to an entry further
  /// left, which would be client-controlled again.
  static func clientAddress(headers: HTTPHeaders, remoteAddress: SocketAddress?) -> String? {
    let rightmost = headers[.xForwardedFor]
      .joined(separator: ",")
      .split(separator: ",", omittingEmptySubsequences: false)
      .last?
      .trimmingCharacters(in: .whitespaces)

    // `SocketAddress(ipAddress:port:)` accepts only a literal IPv4 or IPv6 address, so it doubles
    // as validation, and its `ipAddress` is canonical: two spellings of one address share a key.
    if let rightmost, !rightmost.isEmpty,
      let parsed = try? SocketAddress(ipAddress: rightmost, port: 0)
    {
      return parsed.ipAddress
    }

    return remoteAddress?.ipAddress
  }
}

extension RateLimiter {
  /// Per-IP ceiling across the whole API. Generous — it is there to stop a runaway client, not
  /// to shape ordinary dashboard traffic.
  static var perAddress: RateLimiter {
    .init(
      scope: .clientAddress,
      limit: Environment.get("RATE_LIMIT_PER_MINUTE").flatMap(Int.init) ?? 300,
      window: .minutes(1),
      name: "ip",
    )
  }

  /// Per-token ceiling on the webhook route. Metrics reporting is inherently low-frequency, so
  /// anything near this is a retry loop rather than legitimate use.
  static var perServiceToken: RateLimiter {
    .init(
      scope: .serviceToken,
      limit: Environment.get("WEBHOOK_RATE_LIMIT_PER_MINUTE").flatMap(Int.init) ?? 60,
      window: .minutes(1),
      name: "token",
    )
  }
}
