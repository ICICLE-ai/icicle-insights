import Vapor

/// Reusable service for calling Tapis APIs. Thin wrapper over Vapor's async `Client` —
/// not a separate HTTP stack. Register once on `Application` (see `Application+Tapis`) and
/// reach it from any job/controller via `app.tapis` / `req.application.tapis`.
struct TapisClient: Sendable {
    let client: any Client
    let config: TapisConfig

    var vaults: Vaults {
        Vaults(client: client, config: config)
    }

    // var auth: Auth {
    //     Auth(client: client, config: config)
    // }
    //
    // var mlHub: MLHub {
    //     MLHub(client: client, config: config)
    // }
}



enum TapisClientError: Error, Sendable {
    case requestFailed(status: HTTPResponseStatus)
    case invalidResponse
    case secretNotFound(name: String)
}

/// Let Tapis failures propagate straight out of controllers: `ErrorMiddleware` renders the
/// status and reason, and logs the error at `.warning` with the request's method and URL.
extension TapisClientError: AbortError {
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
