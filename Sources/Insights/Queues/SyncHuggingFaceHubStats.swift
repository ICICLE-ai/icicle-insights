import Fluent
import Foundation
import Queues
import Vapor

/// Minimal queue payload identifying the Hugging Face resource to synchronize.
struct HuggingFaceResource: Codable {
  let id: UUID
}

/// Snapshot and lifetime fields returned by the Hugging Face Hub API.
struct HuggingFaceRepoStatsResponse: Content {
  /// Trailing 30 days, not a lifetime figure — the Hub reports it as a rolling window.
  let downloads: Int
  /// Cumulative since the Hub began counting. Reported directly, so it is stored as a
  /// snapshot; accumulating `downloads` instead would re-add the days two sweeps share.
  let downloadsAllTime: Int
  let likes: Int
}

/// Synchronizes rolling and lifetime Hub statistics for one resource.
struct SyncHuggingFaceHubStats: AsyncJob {
  let baseUrl = "https://huggingface.co/api"
  typealias Payload = HuggingFaceResource

  /// Resolves credentials, fetches Hub statistics, and persists a coherent snapshot.
  func dequeue(_ context: QueueContext, _ payload: HuggingFaceResource) async throws {
    guard
      let resource = try await Resource.query(on: context.application.db)
        .filter(\.$id == payload.id)
        .with(\.$account)
        .first()
    else {
      throw JobError.entryNotFound(id: payload.id)
    }

    guard
      let vault = try await Vault.query(on: context.application.db)
        .filter(\.$account.$id == resource.$account.id)
        .first()
    else {
      throw JobError.missingToken(id: resource.$account.id)
    }

    let token = try await context.application.secrets.readSecret(named: vault.name)
    let headers = HTTPHeaders([
      ("Accept", "application/json"),
      ("Authorization", "Bearer \(token.getSecretValue())"),
    ])
    let stats = try await fetchRepoStats(
      context, owner: resource.account.name, name: resource.name, kind: resource.type,
      headers: headers)

    let resourceID = try resource.requireID()
    let metrics = [
      Metric(resourceID: resourceID, reading: Double(stats.downloads), type: .downloads),
      Metric(resourceID: resourceID, reading: Double(stats.likes), type: .likes),
    ]

    try await metrics.create(on: context.application.db)

    // Set, not accumulated: `downloads` is a rolling 30-day window, and the Hub reports the
    // lifetime figure itself, so a snapshot is both correct and safe to re-run.
    try await Metric.setAllTime(
      on: context.application.db,
      resourceID: resourceID,
      type: .downloads,
      reading: Double(stats.downloadsAllTime)
    )
  }

  /// Fetches expanded rolling downloads, lifetime downloads, and likes from the Hub API.
  func fetchRepoStats(
    _ context: QueueContext,
    owner: String,
    name: String,
    kind: ResourceType,
    headers: HTTPHeaders
  ) async throws -> HuggingFaceRepoStatsResponse {
    // The Hub splits its API by repo kind; everything we sync is a model or a dataset.
    let segment = kind == .dataset ? "datasets" : "models"
    // `downloadsAllTime` is absent by default. `expand[]` is a whitelist, not an addition —
    // the response holds only what is listed, so every field needed must be named.
    let expanded = ["downloads", "downloadsAllTime", "likes"]
      .map { "expand[]=\($0)" }
      .joined(separator: "&")
    let url = URI(string: "\(baseUrl)/\(segment)/\(owner)/\(name)?\(expanded)")
    let response = try await context.application.client.get(url) { req in
      req.headers.add(contentsOf: headers)
    }

    guard response.status == .ok else {
      throw JobError.apiRequestFailed(
        url: url.string,
        statusCode: Int(response.status.code)
      )
    }

    do {
      return try response.content.decode(HuggingFaceRepoStatsResponse.self)
    } catch {
      throw JobError.decodingFailed(url: url.string, underlying: error)
    }
  }
}
