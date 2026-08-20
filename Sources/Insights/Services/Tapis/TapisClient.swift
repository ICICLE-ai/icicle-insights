import Vapor

/// Lightweight client facade for tenant-scoped Tapis services.
///
/// Its `vaults` service conforms to ``SecretProvider`` and is selected at the application's
/// composition root; collection jobs never depend on this Tapis-specific type.
struct TapisClient: Sendable {
  let client: any Client
  let config: TapisConfig

  /// A client bound to Tapis Vault operations.
  var vaults: Vaults {
    Vaults(client: client, config: config)
  }
}

/// Typed failures returned by Tapis service operations and payload decoding.
enum TapisClientError: Error, Sendable {
  case requestFailed(status: HTTPResponseStatus)
  case invalidResponse
  case secretNotFound(name: String)

  /// Whether this failure means "the secret is not there", as opposed to "the request was
  /// refused" or "the service is broken".
  ///
  /// The distinction is what lets a caller treat an absent secret as a setup step still pending
  /// while a 401 stays a hard failure. Both spellings are real: the Vault read checks the status
  /// before decoding, so a missing secret arrives as `requestFailed(.notFound)`, while a response
  /// that succeeds but omits the name arrives as `secretNotFound`.
  var isNotFound: Bool {
    switch self {
    case .secretNotFound:
      true
    case .requestFailed(let status):
      status == .notFound
    case .invalidResponse:
      false
    }
  }
}

/// Let Tapis failures propagate straight out of controllers: `ErrorMiddleware` renders the
/// status and reason, and logs the error at `.warning` with the request's method and URL.
extension TapisClientError: AbortError {
  /// HTTP status exposed when the failure crosses an API boundary.
  var status: HTTPResponseStatus {
    switch self {
    case .secretNotFound:
      .notFound
    case .invalidResponse:
      .badGateway
    // 5xx upstream means Tapis failed. 4xx means we sent something wrong — a stale
    // service token or a bad body — which our caller cannot fix, so it reads as a 500.
    case .requestFailed(let status):
      status.code >= 500 ? .badGateway : .internalServerError
    }
  }

  /// Safe client-facing explanation that excludes credential values.
  var reason: String {
    switch self {
    case .secretNotFound(let name):
      "Secret '\(name)' not found in Tapis."
    case .invalidResponse:
      "Tapis returned an unreadable response."
    case .requestFailed(let status):
      "Tapis request failed with status \(status.code)."
    }
  }
}
