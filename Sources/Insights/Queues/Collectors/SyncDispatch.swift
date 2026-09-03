import Fluent
import Logging
import Queues

import struct Foundation.UUID

extension Queue {
  /// Routes a resource to the sync job for its account's platform.
  ///
  /// Platform, not `Resource.type`, picks the job: type says what a thing is, not which API
  /// reports on it, and a `.repository` can live on either host. Platforms with no job yet are
  /// legitimately in the catalog, just not collectable, so they are skipped rather than thrown.
  ///
  /// `maxRetryCount` defaults to the scheduled budget and is only lowered by the operator-facing
  /// trigger, which trades riding out a throttle for an answer arriving while someone is still
  /// watching. See `Job+Retry.swift` for what the budget buys an unattended sweep.
  func dispatchSync(
    for resource: Resource,
    platform: Platform,
    logger: Logger,
    maxRetryCount: Int = syncJobMaxRetryCount,
  ) async throws {
    let id = try resource.requireID()

    switch platform {
    case .github:
      try await dispatch(
        SyncGitHubRepoStats.self, .init(id: id), maxRetryCount: maxRetryCount)
    case .huggingface:
      try await dispatch(
        SyncHuggingFaceHubStats.self, .init(id: id), maxRetryCount: maxRetryCount)
    case .patra:
      try await dispatch(
        SyncPatraDeployments.self, .init(id: id), maxRetryCount: maxRetryCount)
    case .ghcr, .npm, .pypi:
      logger.debug(
        "No sync job for platform; skipping resource",
        metadata: ["platform": .string(platform.rawValue), "resource": .string(id.uuidString)]
      )
    }
  }
}
