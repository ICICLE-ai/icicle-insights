import Fluent
import Vapor
import VaporToOpenAPI

extension Account {
    struct Create: Content, WithExample {
        var name: String
        var platform: Platform

        enum CodingKeys: String, CodingKey {
            case name, platform
        }

        static let example = Create(name: "octocat", platform: .github)

        func toModel() throws -> Account {
            let model = Account()
            model.name = try requireNonBlank(name, "name").lowercased()
            model.platform = platform
            model.followers = 0
            return model
        }
    }

    struct Update: Content, WithExample {
        var followers: Int?

        enum CodingKeys: String, CodingKey {
            case followers
        }

        static let example = Update(followers: 12_000)
    }

    struct Public: Content {
        var id: UUID?
        var name: String?
        var platform: Platform?
        var followers: Int?
        var resources: [Resource.Public]?
        var vault: Vault.Public?
        var createdAt: Date?
        var updatedAt: Date?
        var deletedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, name, platform, followers, resources, vault, createdAt, updatedAt, deletedAt
        }
    }

    func toPublic() -> Public {
        .init(
            id: id,
            name: $name.value,
            platform: $platform.value,
            followers: $followers.value,
            resources: $resources.value?.map { $0.toPublic() },
            vault: ($vault.value ?? nil)?.toPublic(),
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
        )
    }
}
