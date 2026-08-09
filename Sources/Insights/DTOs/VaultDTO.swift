import Fluent
import Vapor
import VaporToOpenAPI

extension Vault {
  /// Calendar components used to validate a platform token expiration date.
  struct Expires: Content {
    /// One-based calendar day.
    var day: Int
    /// One-based calendar month.
    var month: Int
    /// Four-digit calendar year supported by the API.
    var year: Int

    enum CodingKeys: String, CodingKey {
      case day, month, year
    }

    /// A token that has already expired is never usable, so the date must be in the future.
    func toDate() throws -> Date {
      try requireFuture(
        requireCalendarDate(
          year: requireInRange(year, supportedYears, "year"),
          month: requireInRange(month, 1...12, "month"),
          day: requireInRange(day, 1...31, "day"),
          "expires",
        ),
        "expires",
      )
    }
  }

  /// Request body for creating Tapis Vault metadata and its secret value.
  struct Create: Content, WithExample {
    /// Tapis Vault secret name stored in local metadata.
    var name: String
    /// Platform token written to Tapis Vault and never persisted locally.
    var token: String
    /// Account that uses the platform token.
    var accountID: Account.IDValue
    /// Future expiration date for operational rotation.
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

    /// Validates metadata and converts it into an unsaved Fluent model.
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

  /// Request body for rotating a Tapis Vault secret and expiration date.
  struct Update: Content, WithExample {
    /// Replacement platform token written to Tapis Vault.
    var token: String
    /// Future expiration date for the replacement token.
    var expires: Expires

    enum CodingKeys: String, CodingKey {
      case token, expires
    }

    static let example = Update(
      token: "ghp_exampleToken",
      expires: Expires(day: 31, month: 12, year: 2030),
    )
  }

  /// Public Vault metadata; deliberately excludes the secret value.
  struct Public: Content {
    var id: UUID?
    /// Account that uses the referenced secret.
    var accountID: Account.IDValue?
    /// Tapis Vault secret name; never the secret value.
    var name: String?
    /// Expected token expiration date.
    var expiresAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, accountID, name, expiresAt, createdAt, updatedAt
    }
  }

  /// Projects loaded metadata into a redacted public API shape.
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
