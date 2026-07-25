import Fluent
import Foundation
import Queues
import Vapor

struct GitHubAccount: Codable {
    let id: UUID
}

struct SyncGitHubAccountJob: AsyncJob {
    let baseUrl = "https://api.github.com/orgs"
    typealias Payload = GitHubAccount

    func dequeue(_ context: QueueContext, _ payload: GitHubAccount) async throws {
        guard let account = try await Account.find(payload.id, on: context.application.db) else {
            throw JobError.entryNotFound(id: payload.id)
        }

        guard let vault = try await Vault.query(on: context.application.db)
            .filter(\.$account.$id == payload.id)
            .first()
        else {
            throw JobError.missingToken(id: payload.id)
        }

        // Resolve the account's access token from Tapis Vault.
        let token = try await context.application.tapis.readSecret(named: vault.name)

        let url = baseUrl + "/\(account.name)"
        let response = try await context.application.client.get(URI(string: url)) { req in
            req.headers.add(name: .accept, value: "application/vnd.github+json")
            req.headers.add(name: .authorization, value: "Bearer \(token)")
        }
        _ = response // TODO(you): decode the GitHub response and update account/metrics.
    }

    // func error(_ context: QueueContext, _ error: Error, _ payload: GitHubAccount) async throws {
    // context.
    // }
}
