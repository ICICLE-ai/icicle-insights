import Vapor

/// Typed, fail-fast configuration for talking to Tapis, loaded from the environment.
///
/// Vapor auto-loads `.env` files, so `TAPIS_BASE_URL` / `TAPIS_TOKEN` can live in a
/// gitignored `.env` during development. `fromEnvironment()` throws at boot if either is
/// missing rather than failing later on the first Vault call.
struct TapisConfig: Sendable {
    let baseURL: String
    let token: Secret

    static func fromEnvironment() throws -> TapisConfig {
        guard let baseURL = Environment.get("TAPIS_BASE_URL") else {
            throw ConfigError.missing("TAPIS_BASE_URL")
        }
        guard let token = Environment.get("TAPIS_TOKEN") else {
            throw ConfigError.missing("TAPIS_TOKEN")
        }
        return .init(baseURL: baseURL, token: Secret(token))
    }
}
