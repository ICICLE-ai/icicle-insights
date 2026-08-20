import Fluent
import JWT
import Vapor

import struct Foundation.UUID

/// Authenticates a deployed service by the webhook token it presents.
///
/// Signature and expiry are checked first, against this server's own key collection. That is
/// deliberately the cheap half: it rejects Tapis tokens, anonymous traffic, and noise without
/// touching Postgres, so the database is only consulted for a token this server actually minted.
struct ServiceTokenAuthenticator: AsyncBearerAuthenticator {
  func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
    guard !bearer.token.isEmpty else { return }

    let payload: WebhookToken

    do {
      payload = try await request.application.serviceTokenKeys.verify(
        bearer.token,
        as: WebhookToken.self
      )
    } catch {
      // Not one of ours: a Tapis token, an expired or forged one, or noise. Return quietly
      // rather than throwing — TapisAuthenticator still gets its turn, public reads still work
      // for anonymous callers, and `Require` decides the status at the end.
      //
      // Logged for the same reason as the Tapis side: this path also swallows a genuine
      // problem — a token signed with a key dropped by one rotation too many verifies exactly
      // like a forged one, and would otherwise be an unexplained 401 for a service that had
      // been reporting happily for months.
      request.logger.debug(
        "Bearer value did not verify as a webhook token.",
        metadata: ["error": .string("\(error)")]
      )
      return
    }

    guard let jti = UUID(uuidString: payload.tokenID.value) else {
      request.logger.debug("Webhook token carried a `jti` that is not a UUID.")
      return
    }

    // The one thing a signature cannot express. Revocation is immediate precisely because this
    // is read per request rather than cached at boot.
    guard
      let record = try await ServiceToken.query(on: request.db)
        .filter(\.$jti == jti)
        .first()
    else {
      // A valid signature with no row behind it: the token was deleted rather than revoked.
      // Notice rather than debug — this is a correctly signed credential this server minted, so
      // it is worth seeing without turning debug logging on.
      request.logger.notice(
        "Webhook token verified but has no matching record; treating as unauthenticated.",
        metadata: ["jti": .string(jti.uuidString)]
      )
      return
    }

    guard record.isLive else {
      request.logger.notice(
        "Revoked or expired webhook token presented.",
        metadata: [
          "jti": .string(jti.uuidString),
          "label": .string(record.label),
        ]
      )
      return
    }

    request.auth.login(
      ServiceClient(
        jti: jti,
        resourceID: record.$resource.id,
        label: record.label,
      )
    )
  }
}
