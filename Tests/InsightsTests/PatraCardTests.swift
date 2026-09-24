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

/// `Resource.Public.card`: which card stands for a resource, what it is called, and the exact JSON
/// the dashboard's Models page is built against. Pure projection over hand-built rows, no
/// database — `toPublic()` only ever reads what eager loading already put on the resource, so
/// setting `$patraCards.value` directly is exactly the state `index` and `show` hand it.
@Suite("Patra card projection")
struct PatraCardProjectionTests {
  private let resourceID = UUID()

  /// A resource of `type` whose Patra cards are "loaded" as `cards`, or not loaded at all when
  /// `cards` is nil.
  private func resource(type: ResourceType, cards: [PatraCard]?) -> Resource {
    let resource = Resource(id: resourceID, name: "bioclip", type: type, accountID: UUID())
    if let cards { resource.$patraCards.value = cards }
    return resource
  }

  private func card(
    _ uuid: String, updatedAt: Date? = nil, createdAt: Date? = nil,
    description: String? = nil
  ) -> PatraCard {
    let card = PatraCard(
      resourceID: resourceID, cardUUID: uuid, cardUpdatedAt: updatedAt, createdAt: createdAt)
    card.cardDescription = description
    return card
  }

  private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

  @Test
  func `The most recently updated card stands for the resource`() {
    // Created in the opposite order to their Patra timestamps, so `created_at` alone would pick
    // the wrong one.
    let cards = [
      card("old", updatedAt: day(10), createdAt: day(30), description: "old"),
      card("new", updatedAt: day(20), createdAt: day(1), description: "new"),
    ]

    let projected = resource(type: .model, cards: cards).toPublic()

    #expect(projected.card?.uuid == "new")
    #expect(projected.card?.description == "new")
  }

  @Test
  func `A card with no Patra timestamp ranks below a dated one, and created_at breaks ties`() {
    let undated = card("undated", createdAt: day(99))
    let dated = card("dated", updatedAt: day(1), createdAt: day(1))
    #expect(PatraCard.newest(of: [undated, dated])?.cardUUID == "dated")

    let earlier = card("earlier", updatedAt: day(5), createdAt: day(1))
    let later = card("later", updatedAt: day(5), createdAt: day(2))
    #expect(PatraCard.newest(of: [later, earlier])?.cardUUID == "later")
    #expect(PatraCard.newest(of: [earlier, later])?.cardUUID == "later")

    // Nothing to tell them apart but the uuid, so the choice is stable whatever the row order.
    let a = card("a")
    let b = card("b")
    #expect(PatraCard.newest(of: [a, b])?.cardUUID == PatraCard.newest(of: [b, a])?.cardUUID)
  }

  @Test
  func `kind is model for a model, datasheet for a dataset, and nothing else has a card`() {
    let cards = [card("c", updatedAt: day(1))]
    #expect(resource(type: .model, cards: cards).toPublic().card?.kind == .model)
    #expect(resource(type: .dataset, cards: cards).toPublic().card?.kind == .datasheet)

    for type in ResourceType.allCases where type != .model && type != .dataset {
      #expect(PatraCard.Kind(resourceType: type) == nil)
      #expect(resource(type: type, cards: cards).toPublic().card == nil, "\(type)")
    }
  }

  @Test
  func `card is nil with no cards, and nil when cards were not loaded`() {
    let loadedNone = resource(type: .model, cards: []).toPublic()
    #expect(loadedNone.card == nil)
    // `links` keeps the loaded-versus-not distinction `card` cannot.
    #expect(loadedNone.links == [])

    let notLoaded = resource(type: .model, cards: nil).toPublic()
    #expect(notLoaded.card == nil)
    #expect(notLoaded.links == nil)
  }

  @Test
  func `Keywords split on commas, trimmed, with empty entries dropped`() {
    #expect(
      PatraCard.splitKeywords("yolo, ultralytics,, object detection ,")
        == ["yolo", "ultralytics", "object detection"])
    #expect(PatraCard.splitKeywords("HVDYOL") == ["HVDYOL"])
    #expect(PatraCard.splitKeywords(" , ,") == nil)
    #expect(PatraCard.splitKeywords("") == nil)
    #expect(PatraCard.splitKeywords(nil) == nil)
  }

  /// The contract the dashboard is built against: exactly these keys, camelCase, every one
  /// present, and a missing value an explicit `null`.
  @Test
  func `The card encodes every key, with null for a missing value`() throws {
    let model = card("bioclip-1", updatedAt: day(1), description: "Biology foundation model.")
    model.keywords = "biology, taxonomy"
    model.accuracy = 0.88
    model.isGated = false
    model.sourceURL = "https://huggingface.co/imageomics/bioclip-2"
    let projected = try #require(resource(type: .model, cards: [model]).toPublic().card)

    let data = try JSONEncoder().encode(projected)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(
      Set(object.keys) == [
        "kind", "uuid", "version", "updatedAt", "description", "author", "category", "license",
        "framework", "modelType", "inputType", "accuracy", "keywords", "gated", "size", "format",
        "publicationYear", "sourceURL",
      ])
    #expect(object["kind"] as? String == "model")
    #expect(object["uuid"] as? String == "bioclip-1")
    #expect(object["keywords"] as? [String] == ["biology", "taxonomy"])
    #expect(object["gated"] as? Bool == false)
    #expect(object["accuracy"] as? Double == 0.88)
    #expect(object["size"] is NSNull)
    #expect(object["license"] is NSNull)
    #expect(object["version"] is NSNull)

    // And it reads back as it was written, which is what the controller tests decode through.
    #expect(try JSONDecoder().decode(PatraCard.Public.self, from: data) == projected)
  }
}
