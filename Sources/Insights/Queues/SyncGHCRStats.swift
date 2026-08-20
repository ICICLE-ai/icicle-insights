import Fluent
import Foundation
import Queues
import SwiftSoup
import Vapor

/// Minimal queue payload for the dormant GHCR scraper prototype.
struct GHCRResource: Codable {
  let id: UUID
}

/// Prototype job intended to scrape public GHCR package statistics from GitHub HTML.
///
/// This job is not currently registered or routed and therefore cannot be dispatched.
struct SyncGHCRStats: AsyncJob {
  let baseUrl = "https://github.com/orgs"
  typealias Payload = GHCRResource

  /// Confirms the target resource exists, in preparation for scraping its public package page.
  ///
  /// The scrape itself is unwritten, so this stops at the existence check. Tested as a boolean
  /// rather than bound to a name: nothing uses the row yet, and binding it only produces an
  /// unused-value warning that trains the eye to ignore warnings.
  func dequeue(_ context: QueueContext, _ payload: GHCRResource) async throws {
    let exists =
      try await Resource.query(on: context.application.db)
      .filter(\.$id == payload.id)
      .with(\.$account)
      .first() != nil

    guard exists else {
      throw JobError.entryNotFound(id: payload.id)
    }
  }
}
