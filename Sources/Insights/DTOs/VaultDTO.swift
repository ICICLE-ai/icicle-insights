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
    }

    struct Create: Content, WithExample {
        var token: String
        var accountID: Account.IDValue
        var expires: Expires

        enum CodingKeys: String, CodingKey {
            case token, accountID, expires
        }

        static let example = Create(
            token: "ghp_exampleToken",
            accountID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
            expires: Expires(day: 31, month: 12, year: 2026),
        )

        func toModel() -> Vault {
            let model = Vault()
            model.$account.id = accountID

            var expirationDate = DateComponents()
            expirationDate.day = expires.day
            expirationDate.month = expires.month
            expirationDate.year = expires.year

            model.expiresAt = Calendar(identifier: .gregorian).date(from: expirationDate)
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
            expires: Expires(day: 31, month: 12, year: 2026),
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
