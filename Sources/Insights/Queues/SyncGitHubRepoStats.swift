import Fluent
import Foundation
import Queues
import Vapor

/// Minimal queue payload identifying the resource to synchronize from GitHub.
struct GitHubResource: Codable {
  let id: UUID
}

/// Snapshot fields returned by GitHub's repository endpoint.
struct GitHubRepoStatsResponse: Content {
  let stargazers_count: Int
  let forks_count: Int
  let subscribers_count: Int
}

/// One completed day of traffic. GitHub stamps these at UTC midnight.
/// One UTC day from a GitHub traffic rolling window.
struct TrafficDay: Decodable, Sendable {
  let timestamp: Date
  let count: Int
  let uniques: Int
}

/// Decode-only, unlike the other response types here: the custom initializer below leaves
/// `days` with no key of its own, so `Encodable` cannot be synthesised. Nothing encodes it.
/// Normalized clone or view response, including its per-day readings.
struct GitHubRepoTrafficResponse: Decodable, Sendable {
  /// Rolling 14-day total, not a delta. Kept as the `clones`/`views` reading, but folding it
  /// into an all-time total would re-add every day two sweeps share; `days` feeds that.
  let count: Int
  let uniques: Int
  let days: [TrafficDay]

  private enum CodingKeys: String, CodingKey {
    case count, uniques, clones, views
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    count = try container.decode(Int.self, forKey: .count)
    uniques = try container.decode(Int.self, forKey: .uniques)
    // The endpoints differ only in the array's name: `clones` on one, `views` on the other.
    days =
      try container.decodeIfPresent([TrafficDay].self, forKey: .clones)
      ?? container.decodeIfPresent([TrafficDay].self, forKey: .views)
      ?? []
  }
}

/// GitHub traffic endpoints supported by the repository synchronization job.
enum TrafficEndpoint: String {
  case clones, views

  /// The metric each endpoint feeds, so the caller cannot pair a response with the wrong
  /// watermark.
  /// Metric type associated with the endpoint's rolling window.
  var metric: MetricType {
    switch self {
    case .clones: .clones
    case .views: .views
    }
  }
}

/// Synchronizes GitHub repository snapshots and traffic windows for one resource.
struct SyncGitHubRepoStats: AsyncJob, BackoffRetrying {
  let baseUrl = "https://api.github.com/repos"
  typealias Payload = GitHubResource

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: GitHubResource) async throws {
    await context.reportResourceSyncFailure(error, job: Self.name, resourceID: payload.id)
  }

  /// Resolves credentials, fetches all repository responses, then persists one coherent sweep.
  func dequeue(_ context: QueueContext, _ payload: GitHubResource) async throws {
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
    let owner = resource.account.name
    let headers = HTTPHeaders([
      ("Accept", "application/vnd.github+json"),
      ("Authorization", "Bearer \(token.getSecretValue())"),
      ("X-GitHub-Api-Version", "2026-03-10"),
      // Required by GitHub: requests without one are rejected with 403, not 400.
      ("User-Agent", "icicle-insights"),
    ])
    let repoStats = try await fetchRepoStats(
      context, owner: owner, name: resource.name, headers: headers)
    let clones = try await fetchTrafficStats(
      context, owner: owner, name: resource.name, headers: headers, endpoint: .clones
    )
    let views = try await fetchTrafficStats(
      context, owner: owner, name: resource.name, headers: headers, endpoint: .views
    )

    let resourceID = try resource.requireID()
    let metrics = [
      Metric(resourceID: resourceID, reading: Double(repoStats.stargazers_count), type: .stars),
      Metric(resourceID: resourceID, reading: Double(repoStats.forks_count), type: .forks),
      Metric(
        resourceID: resourceID, reading: Double(repoStats.subscribers_count), type: .subscribers),
      Metric(resourceID: resourceID, reading: Double(clones.count), type: .clones),
      Metric(resourceID: resourceID, reading: Double(views.count), type: .views),
    ]

    try await metrics.create(on: context.application.db)

    // Stars, forks, and subscribers are gauges — reported in full each time, so the series is
    // the record and `MetricType.allTime` is nil for them. Only the rolling windows accumulate.
    for (traffic, endpoint) in [(clones, TrafficEndpoint.clones), (views, .views)] {
      try await Metric.foldDailyIntoAllTime(
        on: context.application.db,
        resourceID: resourceID,
        type: endpoint.metric,
        days: traffic.days
      )
    }
  }

  /// Fetches the repository snapshot using the supplied GitHub bearer token.
  func fetchRepoStats(
    _ context: QueueContext,
    owner: String,
    name: String,
    headers: HTTPHeaders
  ) async throws -> GitHubRepoStatsResponse {
    let url = URI(string: "\(baseUrl)/\(owner)/\(name)")
    let response = try await context.application.client.get(url) { req in
      req.headers.add(contentsOf: headers)
    }

    guard response.status == .ok else {
      throw JobError.apiRequestFailed(url: url, response: response)
    }

    do {
      return try response.content.decode(GitHubRepoStatsResponse.self)
    } catch {
      throw JobError.decodingFailed(url: url.string, underlying: error)
    }
  }

  /// Fetches and decodes one GitHub traffic rolling window.
  func fetchTrafficStats(
    _ context: QueueContext,
    owner: String,
    name: String,
    headers: HTTPHeaders,
    endpoint: TrafficEndpoint
  ) async throws -> GitHubRepoTrafficResponse {
    let url = URI(string: "\(baseUrl)/\(owner)/\(name)/traffic/\(endpoint.rawValue)")
    let response = try await context.application.client.get(url) { req in
      req.headers.add(contentsOf: headers)
    }

    guard response.status == .ok else {
      throw JobError.apiRequestFailed(url: url, response: response)
    }

    do {
      return try response.content.decode(GitHubRepoTrafficResponse.self)
    } catch {
      throw JobError.decodingFailed(url: url.string, underlying: error)
    }
  }
}
