import Vapor

/// Reusable service for calling Tapis APIs. Thin wrapper over Vapor's async `Client` —
/// not a separate HTTP stack. Register once on `Application` (see `Application+Tapis`) and
/// reach it from any job/controller via `app.tapis` / `req.application.tapis`.
struct TapisClient: Sendable {
    let client: any Client
    let config: TapisConfig

    /// Resolve a Vault secret *name* into its actual value, authenticated with the Tapis
    /// service token.
    func readSecret(named name: String) async throws -> String {
        // TODO(you): set the exact Tapis SK Vault read path for `name`.
        let uri = URI(string: "\(config.baseURL)/v3/security/vault/secret/\(name)")

        let response = try await client.get(uri) { req in
            req.headers.add(name: "X-Tapis-Token", value: config.token.rawValue)
        }

        guard response.status == .ok else {
            throw JobError.apiRequestFailed(
                statusCode: Int(response.status.code),
                message: "Tapis Vault read failed for secret '\(name)'",
            )
        }

        // TODO(you): decode the real Tapis SK envelope and pull the secret value out.
        return try response.content.decode(TapisSecretResponse.self).result.secretValue
    }
}

/// TODO(you): match this to the actual Tapis SK read-secret response body.
struct TapisSecretResponse: Content {
    struct Result: Content {
        let secretValue: String
    }

    let result: Result
}
