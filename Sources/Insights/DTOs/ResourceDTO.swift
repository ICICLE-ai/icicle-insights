import Fluent
import Vapor
import VaporToOpenAPI

extension Resource {
    struct Create: Content, WithExample {
        var name: String
        var type: ResourceType
        var accountID: Account.IDValue

        enum CodingKeys: String, CodingKey {
            case name, type, accountID
        }

        static let example = Create(
            name: "insights",
            type: .model,
            accountID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
        )

        func toModel() -> Resource {
            let model = Resource()
            model.name = name
            model.type = type
            model.$account.id = accountID
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
        var createdAt: Date?
        var updatedAt: Date?
        var deletedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, accountID, name, type, metrics, releases, createdAt, updatedAt, deletedAt
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
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
        )
    }
}
