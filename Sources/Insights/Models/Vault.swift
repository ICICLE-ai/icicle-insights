import Fluent
import struct Foundation.Date
import struct Foundation.UUID

final class Vault: Model, @unchecked Sendable {
    static let schema = "vaults"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "account_id")
    var account: Account

    @Field(key: "name")
    var name: String

    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        accountID: Account.IDValue,
        name: String,
        expiresAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
    ) {
        self.id = id
        $account.id = accountID
        self.name = name
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
