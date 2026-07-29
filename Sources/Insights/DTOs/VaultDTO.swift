import Fluent
import Vapor
import VaporToOpenAPI

extension Vault {
    struct Expires: Content {
        var day: Int
        var month: Int
        var year: Int

        enum CodingKeys: String, CodingKey {
            case day, month, year
        }

        /// A token that has already expired is never usable, so the date must be in the future.
        func toDate() throws -> Date {
            try requireFuture(
                requireCalendarDate(
                    year: requireInRange(year, supportedYears, "year"),
                    month: requireInRange(month, 1 ... 12, "month"),
                    day: requireInRange(day, 1 ... 31, "day"),
                    "expires",
                ),
                "expires",
            )
        }
    }

    struct Create: Content, WithExample {
        var name: String
        var token: String
        var accountID: Account.IDValue
        var expires: Expires

        enum CodingKeys: String, CodingKey {
            case name, token, accountID, expires
        }

        static let example = Create(
            name: "github-token",
            token: "ghp_exampleToken",
            accountID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
            expires: Expires(day: 31, month: 12, year: 2030),
        )

        func toModel() throws -> Vault {
            let model = Vault()
            model.name = try requireNonBlank(name, "name").lowercased()
            model.$account.id = accountID

            // Validated here even though the token is not persisted yet — see the TODO in
            // VaultController.create.
            _ = try requireNonBlank(token, "token")

            model.expiresAt = try expires.toDate()
            return model
        }
    }

    struct Update: Content, WithExample {
        var token: String
        var expires: Expires

        enum CodingKeys: String, CodingKey {
            case token, expires
        }

        static let example = Update(
            token: "ghp_exampleToken",
            expires: Expires(day: 31, month: 12, year: 2030),
        )
    }

    struct Public: Content {
        var id: UUID?
        var accountID: Account.IDValue?
        var name: String?
        var expiresAt: Date?
        var createdAt: Date?
        var updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, accountID, name, expiresAt, createdAt, updatedAt
        }
    }

    func toPublic() -> Public {
        .init(
            id: id,
            accountID: $account.id,
            name: $name.value,
            expiresAt: expiresAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
        )
    }
}
