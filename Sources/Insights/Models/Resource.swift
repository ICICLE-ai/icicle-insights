import Fluent
import struct Foundation.Date
import struct Foundation.UUID

// CaseIterable is what makes SwiftOpenAPI emit the allowed values as an enum in the
// generated schema rather than a bare string.
enum ResourceType: String, Codable, CaseIterable {
    case container, dataset, image, model, package, repository, service
}

final class Resource: Model, @unchecked Sendable {
    static let schema = "resources"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Enum(key: "type")
    var type: ResourceType

    @Parent(key: "account_id")
    var account: Account

    @Children(for: \.$resource)
    var metrics: [Metric]

    @Children(for: \.$resource)
    var releases: [Release]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Timestamp(key: "deleted_at", on: .delete)
    var deletedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        type: ResourceType,
        accountID: Account.IDValue,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
    ) {
        self.id = id
        self.name = name
        self.type = type
        $account.id = accountID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
