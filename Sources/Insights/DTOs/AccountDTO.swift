import Fluent
import Vapor
import VaporToOpenAPI

extension Account {
  /// Request body for creating a platform account.
  struct Create: Content, WithExample {
    /// Platform account or organization name.
    var name: String
    /// Provider that owns the account and controls job routing.
    var platform: Platform

    enum CodingKeys: String, CodingKey {
      case name, platform
    }

    static let example = Create(name: "octocat", platform: .github)

    /// Validates and converts the request into an unsaved Fluent model.
    func toModel() throws -> Account {
      let model = Account()
      model.name = try requireNonBlank(name, "name").lowercased()
      model.platform = platform
      model.followers = 0
      return model
    }
  }

  /// Partial request body for updating account-level measurements.
  struct Update: Content, WithExample {
    /// Latest follower snapshot, when supplied.
    var followers: Int?

    enum CodingKeys: String, CodingKey {
      case followers
    }

    static let example = Update(followers: 12_000)
  }

  /// Public account representation returned by the API.
  struct Public: Content {
    var id: UUID?
    /// Normalized platform account name.
    var name: String?
    /// Provider that owns the account.
    var platform: Platform?
    /// Latest collected follower snapshot.
    var followers: Int?
    /// Loaded resources owned by the account.
    var resources: [Resource.Public]?
    /// Loaded, redacted Vault metadata.
    var vault: Vault.Public?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, name, platform, followers, resources, vault, createdAt, updatedAt, deletedAt
    }
  }

  /// Projects loaded model fields and relationships into the public API shape.
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
