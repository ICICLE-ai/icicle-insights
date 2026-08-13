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

  /// Loads the target resource in preparation for scraping its public package page.
  func dequeue(_ context: QueueContext, _ payload: GHCRResource) async throws {
    guard
      let resource = try await Resource.query(on: context.application.db)
        .filter(\.$id == payload.id)
        .with(\.$account)
        .first()
    else {
      throw JobError.entryNotFound(id: payload.id)
    }
  }
}
