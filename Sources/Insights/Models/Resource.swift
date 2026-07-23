import Fluent
import struct Foundation.Date
import struct Foundation.UUID

enum ResourceType: String, Codable {
    case dataset, image, model, package, service
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
