import Fluent
import Foundation
import Queues
import SwiftSoup
import Vapor

struct GHCRResource: Codable {
  let id: UUID
}

struct SyncGHCRStats: AsyncJob {
  let baseUrl = "https://github.com/orgs"
  typealias Payload = GHCRResource

  func dequeue(_ context: QueueContext, _ payload: GHCRResource) async throws {
    guard let resource = try await Resource.query(on: context.application.db)
    .filter(\.$id == payload.id)
    .with(\.$account)
    .first()
      else {
      throw JobError.entryNotFound(id: payload.id)
    }
  }
}
