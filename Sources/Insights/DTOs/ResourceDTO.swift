import Fluent
import Vapor
import VaporToOpenAPI

extension Resource {
  /// Request body for creating a collectable resource under an account.
  struct Create: Content, WithExample {
    /// Provider-specific resource name or path.
    var name: String
    /// Catalog classification of the resource.
    var type: ResourceType
    /// Account that owns the resource.
    var accountID: Account.IDValue
    /// Days between syncs. Omitted means the default cadence; the create route is what bounds
    /// it against the platform's retention window, since that needs the account.
    var collectionIntervalDays: Int?

    enum CodingKeys: String, CodingKey {
      case name, type, accountID, collectionIntervalDays
    }

    static let example = Create(
      name: "insights",
      type: .model,
      accountID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
      collectionIntervalDays: 7,
    )

    /// Validates and converts the request into an unsaved Fluent model.
    func toModel() throws -> Resource {
      let model = Resource()
      model.name = try requireNonBlank(name, "name").lowercased()
      model.type = type
      model.$account.id = accountID
      model.collectionIntervalDays =
        collectionIntervalDays ?? Resource.defaultCollectionIntervalDays
      return model
    }
  }

  /// Partial request body for editing a collectable resource's own fields.
  ///
  /// Excludes `accountID`: moving a resource between accounts is a different, riskier operation
  /// than correcting its name, kind, or cadence, and nothing in the admin UI asks for it.
  struct Update: Content, WithExample {
    /// Provider-specific resource name or path.
    var name: String?
    /// Catalog classification of the resource.
    var type: ResourceType?
    /// Days between syncs, still bounded by the owning account's platform on save.
    var collectionIntervalDays: Int?

    enum CodingKeys: String, CodingKey {
      case name, type, collectionIntervalDays
    }

    static let example = Update(name: "insights", type: .model, collectionIntervalDays: 7)
  }

  /// One registry where this artifact also exists.
  ///
  /// Flattened from the Patra card that records the relationship: the graph needs a node's
  /// identity and its registry, not the card that produced the edge.
  struct ResourceLink: Content, Equatable {
    var id: UUID?
    var name: String?
    var platform: Platform?
  }

  /// Public resource representation returned by the API.
  struct Public: Content {
    var id: UUID?
    /// Account that owns the resource.
    var accountID: Account.IDValue?
    /// Normalized provider-specific resource name.
    var name: String?
    /// Catalog classification of the resource.
    var type: ResourceType?
    /// Loaded metric history, when requested with the relationship.
    var metrics: [Metric.Public]?
    /// Loaded release history, when requested with the relationship.
    var releases: [Release.Public]?
    /// Other registries this artifact is also known under, deduplicated across this resource's
    /// loaded Patra cards. Nil means not requested; an empty array means requested and none
    /// found — the same "loaded vs. not" contract every other relationship here keeps.
    var links: [ResourceLink]?
    /// What Patra says about this artifact: the resource's most recently updated Patra card, as
    /// chosen by `PatraCard.newest(of:)`. Nil for a resource with no Patra cards, a resource whose
    /// type names no Patra catalog (see `PatraCard.Kind`), or a response that did not load cards.
    ///
    /// Unlike `links`, "loaded, none found" is nil here too, not an empty value: a card is one
    /// object, and there is no empty object to stand for none. `links` still carries the
    /// loaded-versus-not distinction for any client that needs it.
    var card: PatraCard.Public?
    /// Earliest instant at which the due-resource sweep may dispatch it.
    var nextCollectionAt: Date?
    /// Number of days booked between successful dispatches.
    var collectionIntervalDays: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, accountID, name, type, metrics, releases, links, card, nextCollectionAt,
        collectionIntervalDays, createdAt, updatedAt, deletedAt
    }
  }

  /// Projects loaded model fields and child collections into the public API shape.
  ///
  /// `links` and `card` both read only the Patra cards `index` and `show` already eager-loaded, so
  /// adding `card` cost those routes no query at all. Neither is ever fetched from here: a caller
  /// that did not load `patraCards` gets neither, never a lazy load per resource.
  func toPublic() -> Public {
    .init(
      id: id,
      accountID: $account.id,
      name: $name.value,
      type: $type.value,
      metrics: $metrics.value?.map { $0.toPublic() },
      releases: $releases.value?.map { $0.toPublic() },
      links: $patraCards.value.map(Self.links(from:)),
      card: $patraCards.value.flatMap { Self.card(from: $0, resourceType: $type.value) },
      nextCollectionAt: $nextCollectionAt.value ?? nil,
      collectionIntervalDays: $collectionIntervalDays.value,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    )
  }

  /// The public form of the newest of a resource's loaded Patra cards, labelled with the kind its
  /// type implies, or nil when there are no cards or the type names no Patra catalog.
  private static func card(from cards: [PatraCard], resourceType: ResourceType?) -> PatraCard
    .Public?
  {
    guard let resourceType, let kind = PatraCard.Kind(resourceType: resourceType),
      let newest = PatraCard.newest(of: cards)
    else { return nil }
    return newest.toPublic(kind: kind)
  }

  /// Flattens a resource's Patra cards into the distinct non-nil hub/repository resources they
  /// point at.
  ///
  /// Reads only what eager loading already populated (`card.hubResource` / `.repositoryResource`
  /// resolve to nil when unloaded, exactly like an absent relationship — callers must load both
  /// alongside `patraCards`, or every card looks like it names nothing). Dedupes by id: two cards
  /// — say, two versions of the same model — commonly resolve to the same hub resource, and the
  /// graph wants one edge for that, not one per card.
  private static func links(from cards: [PatraCard]) -> [ResourceLink] {
    var seenIDs = Set<UUID>()
    var links: [ResourceLink] = []
    for card in cards {
      for linked in [card.hubResource, card.repositoryResource].compactMap({ $0 }) {
        guard let linkedID = linked.id, seenIDs.insert(linkedID).inserted else { continue }
        links.append(
          ResourceLink(
            id: linkedID,
            name: linked.$name.value,
            platform: linked.$account.value?.platform,
          ))
      }
    }
    return links
  }
}
