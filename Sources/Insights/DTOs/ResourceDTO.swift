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
    /// Earliest instant at which the due-resource sweep may dispatch it.
    var nextCollectionAt: Date?
    /// Number of days booked between successful dispatches.
    var collectionIntervalDays: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, accountID, name, type, metrics, releases, nextCollectionAt,
        collectionIntervalDays, createdAt, updatedAt, deletedAt
    }
  }

  /// Projects loaded model fields and child collections into the public API shape.
  func toPublic() -> Public {
    .init(
      id: id,
      accountID: $account.id,
      name: $name.value,
      type: $type.value,
      metrics: $metrics.value?.map { $0.toPublic() },
      releases: $releases.value?.map { $0.toPublic() },
      nextCollectionAt: $nextCollectionAt.value ?? nil,
      collectionIntervalDays: $collectionIntervalDays.value,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    )
  }
}
