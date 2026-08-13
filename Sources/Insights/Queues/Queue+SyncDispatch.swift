import Fluent
import Logging
import Queues

import struct Foundation.UUID

extension QueueName {
  /// Drained by `queues --queue metrics`. Off `.default` so a sweep's backlog cannot starve
  /// unrelated work queued behind it.
  static let metrics = QueueName(string: "metrics")
}

extension Queue {
  /// Routes a resource to the sync job for its account's platform.
  ///
  /// Platform, not `Resource.type`, picks the job: type says what a thing is, not which API
  /// reports on it, and a `.repository` can live on either host. Platforms with no job yet are
  /// legitimately in the catalog, just not collectable, so they are skipped rather than thrown.
  func dispatchSync(for resource: Resource, platform: Platform, logger: Logger) async throws {
    let id = try resource.requireID()

    switch platform {
    case .github:
      try await dispatch(SyncGitHubRepoStats.self, .init(id: id))
    case .huggingface:
      try await dispatch(SyncHuggingFaceHubStats.self, .init(id: id))
    case .ghcr, .npm, .pypi:
      logger.debug(
        "No sync job for platform; skipping resource",
        metadata: ["platform": .string(platform.rawValue), "resource": .string(id.uuidString)]
      )
    }
  }
}
