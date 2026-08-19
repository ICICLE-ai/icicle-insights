import Vapor

import struct Foundation.UUID

/// Expresses what a route demands of whoever reached it, given that two kinds of caller can
/// authenticate.
///
/// `guardMiddleware()` doesn't fit here: on a route both a human and a service client may use,
/// neither identity is individually required, so the requirement has to be one middleware that
/// accepts either. Authenticators run first and populate `req.auth`; this reads it.
struct Require: AsyncMiddleware {
  let satisfiedBy: @Sendable (Request) -> Bool

  /// Names this requirement in refusal logs. Without it every 403 looks alike, and the useful
  /// question — *which* guard turned this away — has no answer.
  let name: String

  init(name: String, satisfiedBy: @escaping @Sendable (Request) -> Bool) {
    self.name = name
    self.satisfiedBy = satisfiedBy
  }

  /// Humans holding administrative access. Service clients never satisfy this.
  ///
  /// Reads a flag rather than querying, because the lookup already happened in
  /// ``TapisAuthenticator`` — this predicate is synchronous by design, so that the requirement
  /// can be evaluated cheaply on every guarded route.
  static let admin = Require(name: "admin") { request in
    request.auth.get(TapisUser.self)?.isAdmin ?? false
  }

  /// An admin, or the one service client bound to the `:resourceID` in the path.
  ///
  /// Admins are checked first so a human is never locked out of a route a service can reach.
  /// The comparison is what confines a deployed service to its own resource: its token names a
  /// resource inside the signature, so a request aimed anywhere else is refused even though the
  /// token itself is perfectly valid.
  static let resourceScoped = Require(name: "resourceScoped") { request in
    if Require.admin.satisfiedBy(request) { return true }

    guard
      let client = request.auth.get(ServiceClient.self),
      let path = request.parameters.get("resourceID", as: UUID.self)
    else {
      return false
    }

    return client.resourceID == path
  }

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    guard satisfiedBy(request) else {
      // The only place either status is produced. A caller nobody could authenticate is a 401;
      // an authenticated caller lacking permission is a 403. Neither response says which
      // credential was presented, or why it was rejected.
      let authenticated =
        request.auth.has(TapisUser.self) || request.auth.has(ServiceClient.self)

      // The detail withheld from the caller, kept for the operator. Debug rather than warning:
      // on a public API an anonymous request reaching a guarded route is ordinary traffic, not
      // an incident, and logging it louder would bury the failures that matter.
      request.logger.debug(
        "Request refused by requirement.",
        metadata: [
          "requirement": .string(name),
          "authenticated": .stringConvertible(authenticated),
          "caller": .string(callerDescription(request)),
          "status": .stringConvertible(authenticated ? 403 : 401),
        ]
      )

      throw Abort(authenticated ? .forbidden : .unauthorized)
    }

    return try await next.respond(to: request)
  }

  /// Identifies whoever authenticated, for a refusal log line.
  private func callerDescription(_ request: Request) -> String {
    if let user = request.auth.get(TapisUser.self) {
      return "user:\(user.username)"
    }
    if let client = request.auth.get(ServiceClient.self) {
      return "service:\(client.label)"
    }
    return "anonymous"
  }
}
