import Fluent
import Vapor
import VaporToOpenAPI

extension Resource {
  struct Create: Content, WithExample {
    var name: String
    var type: ResourceType
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

  struct Public: Content {
    var id: UUID?
    var accountID: Account.IDValue?
    var name: String?
    var type: ResourceType?
    var metrics: [Metric.Public]?
    var releases: [Release.Public]?
    var nextCollectionAt: Date?
    var collectionIntervalDays: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, accountID, name, type, metrics, releases, nextCollectionAt,
        collectionIntervalDays, createdAt, updatedAt, deletedAt
    }
  }

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
