import Fluent
import Logging
import Queues

import struct Foundation.UUID

extension Queue {
  /// Routes a resource to the sync job for its account's platform.
  ///
  /// Platform, not `Resource.type`, picks the job: type says what a thing is, not which API
  /// reports on it, and a `.repository` can live on either host. Platforms with no job are
  /// legitimately in the catalog, just not collected, so they are skipped rather than thrown.
  func dispatchSync(for resource: Resource, platform: Platform, logger: Logger) async throws {
    let id = try resource.requireID()

    // Asked before the switch, through the property the collect-now route refuses on, so the
    // dispatcher and the route agree on which platforms are collected.
    guard platform.hasCollector else {
      logger.debug(
        "No sync job for platform; skipping resource",
        metadata: ["platform": .string(platform.rawValue), "resource": .string(id.uuidString)]
      )
      return
    }

    switch platform {
    case .github:
      try await dispatch(
        SyncGitHubRepoStats.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
    case .huggingface:
      try await dispatch(
        SyncHuggingFaceHubStats.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
    case .patra:
      try await dispatch(
        SyncPatraDeployments.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
    case .ghcr:
      // The `metrics` queue like every other collector, although this one scrapes HTML rather
      // than calling an API. A queue of its own would need its own worker process in every
      // deployment, for a handful of page fetches a day.
      try await dispatch(
        SyncGHCRStats.self, .init(id: id), maxRetryCount: syncJobMaxRetryCount)
    case .npm, .pypi:
      // Named rather than `default`, so a new platform fails to compile here as well as in
      // `hasCollector`. Reached only if `hasCollector` is changed to true without a job being
      // added above. Throwing makes that loud: the route refuses instead of answering 202 for a
      // job it never queued, and the sweep reports it every hour instead of skipping in silence.
      throw UnroutedPlatform(platform: platform)
    }
  }
}

/// A platform that `Platform.hasCollector` says is collected, but that has no job to dispatch.
///
/// A programming error, never an operating condition. It exists so the mismatch surfaces as a
/// failure rather than as a collection that silently never happens.
struct UnroutedPlatform: Error, CustomStringConvertible {
  /// The platform with no route.
  let platform: Platform

  var description: String {
    "Platform '\(platform.rawValue)' is marked as collected but has no sync job to dispatch."
  }
}
