import Vapor

extension TapisClient {
    struct Vaults: Sendable {
        let client: any Client
        let config: TapisConfig

        /// Resolve a Vault secret *name* into its actual value, authenticated with the Tapis
        /// service token.
        func readSecret(named name: String) async throws -> Secret {
            let uri = URI(string: "\(config.vaultBaseURL)/user/\(name)")

            let response = try await client.get(uri) { req in
                req.headers.add(
                    name: "X-Tapis-Token",
                    value: config.admin.token.getSecretValue()
                )

                try req.query.encode([
                    "tenant": config.tenant,
                    "user": config.admin.name.getSecretValue(),
                ])
            }

            guard response.status == .ok else {
                throw TapisClientError.requestFailed(status: response.status)
            }

            let payload: TapisSecretResponse

            do {
                payload = try response.content.decode(TapisSecretResponse.self)
            } catch {
                throw TapisClientError.invalidResponse
            }

            guard let secretValue = payload.result.secretMap[name] else {
                throw TapisClientError.secretNotFound(name: name)
            }

            return Secret(secretValue)
        }

        func writeSecret(named name: String, secret: String) async throws {
            let uri = URI(string: "\(config.vaultBaseURL)/user/\(name)")
            let response = try await client.post(uri) { req in
                req.headers.add(
                    name: "X-Tapis-Token",
                    value: config.admin.token.getSecretValue()
                )

                try req.content.encode(TapisWriteSecretBody(
                    tenant: config.tenant,
                    user: config.admin.name.getSecretValue(),
                    data: [name: secret]
                ))
            }

            guard response.status == .ok
                || response.status == .created
                || response.status == .noContent
            else {
                throw TapisClientError.requestFailed(status: response.status)
            }
        }

        func destroySecret(named name: String, versions: [Int] = []) async throws {
            let uri = URI(string: "\(config.vaultBaseURL)/destroy/user/\(name)")

            let response = try await client.post(uri) { req in
                req.headers.add(
                    name: "X-Tapis-Token",
                    value: config.admin.token.getSecretValue()
                )

                try req.content.encode(TapisDestroySecretBody(
                    tenant: config.tenant,
                    user: config.admin.name.getSecretValue(),
                    versions: versions
                ))
            }

            guard response.status == .ok
                || response.status == .created
                || response.status == .noContent
            else {
                throw TapisClientError.requestFailed(status: response.status)
            }
        }
    }
}

struct TapisSecretResponse: Content {
    struct Result: Content {
        let secretMap: [String: String]
    }

    let result: Result
}

struct TapisWriteSecretBody: Content {
    let tenant: String
    let user: String
    let data: [String: String]
}

struct TapisDestroySecretBody: Content {
    let tenant: String
    let user: String
    let versions: [Int]
}
