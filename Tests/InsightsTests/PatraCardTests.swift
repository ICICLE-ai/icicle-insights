import Fluent
import Foundation
import Testing

@testable import Insights

/// `card_uuid` is Patra's only stable key — see `PatraCard`'s doc comment — so `patra_cards`
/// enforces it as a genuine database constraint rather than trusting a sync job to check first.
@Suite("Patra card", .serialized)
struct PatraCardTests {
  @Test
  func `A second card with the same card_uuid is rejected`() async throws {
    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .patra)
      let resource = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "yolo11l", type: .model)
      let resourceID = try resource.requireID()

      let first = PatraCard(resourceID: resourceID, cardUUID: "patra-card-uuid-1")
      try await first.create(on: app.db)

      let duplicate = PatraCard(resourceID: resourceID, cardUUID: "patra-card-uuid-1")
      do {
        try await duplicate.create(on: app.db)
        Issue.record("Expected a duplicate card_uuid to violate the unique constraint")
      } catch let error as any DatabaseError {
        #expect(error.isConstraintFailure)
      }

      // The rejected duplicate must not have been left partially written.
      let count = try await PatraCard.query(on: app.db).count()
      #expect(count == 1)
    }
  }
}
