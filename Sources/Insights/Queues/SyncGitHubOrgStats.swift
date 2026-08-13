import Fluent
import Foundation
import Queues
import Vapor

/// Minimal queue payload identifying the GitHub account to synchronize.
struct GitHubAccount: Codable {
  let id: UUID
}

/// Account-level snapshot returned by GitHub's organization endpoint.
struct GitHubOrgStatsResponse: Content {
  let followers: Int
}

/// Synchronizes the follower snapshot for one GitHub organization account.
struct SyncGitHubOrgStats: AsyncJob, BackoffRetrying {
  typealias Payload = GitHubAccount

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: GitHubAccount) async throws {
    await context.reportAccountSyncFailure(error, job: Self.name, accountID: payload.id)
  }

  /// Resolves the account token, fetches followers, and updates the account snapshot.
  func dequeue(_ context: QueueContext, _ payload: GitHubAccount) async throws {
    guard let account = try await Account.find(payload.id, on: context.application.db) else {
      throw JobError.entryNotFound(id: payload.id)
    }

    guard
      let vault = try await Vault.query(on: context.application.db)
        .filter(\.$account.$id == payload.id)
        .first()
    else {
      throw JobError.missingToken(id: payload.id)
    }

    // Resolve the account's access token from Tapis Vault.
    let token = try await context.application.secrets.readSecret(named: vault.name)

    // `/orgs/{org}`, plural — the singular spelling 404s.
    let url = URI("https://api.github.com/orgs/\(account.name)")
    let response = try await context.application.client.get(url) { req in
      req.headers.add(name: .accept, value: "application/vnd.github+json")
      req.headers.add(name: .authorization, value: "Bearer \(token.getSecretValue())")
      req.headers.add(name: "X-GitHub-Api-Version", value: "2026-03-10")
      // Required by GitHub: requests without one are rejected with 403, not 400.
      req.headers.add(name: .userAgent, value: "icicle-insights")
    }

    guard response.status == .ok else {
      throw JobError.apiRequestFailed(url: url, response: response)
    }

    let payload: GitHubOrgStatsResponse

    do {
      payload = try response.content.decode(GitHubOrgStatsResponse.self)
    } catch {
      throw JobError.decodingFailed(url: url.string, underlying: error)
    }

    if account.followers != payload.followers {
      account.followers = payload.followers
      try await account.save(on: context.application.db)
    }
  }
}
