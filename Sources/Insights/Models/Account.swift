import Fluent
import struct Foundation.Date
import struct Foundation.UUID

enum Platform: String, Codable, CaseIterable {
    case github, huggingface, npm, pypi
}

final class Account: Model, @unchecked Sendable {
    static let schema = "accounts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Enum(key: "platform")
    var platform: Platform

    @Field(key: "followers")
    var followers: Int

    @Children(for: \.$account)
    var resources: [Resource]

    @OptionalChild(for: \.$account)
    var vault: Vault?

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
        platform: Platform,
        followers: Int,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.followers = followers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
