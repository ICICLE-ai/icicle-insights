import Fluent
import Vapor
import VaporToOpenAPI

extension Release {
  /// Request body for recording a resource release.
  struct Create: Content, WithExample {
    /// Human-readable release or version identifier.
    var version: String
    /// One-based release month.
    var month: Int
    /// Four-digit release year supported by the API.
    var year: Int
    /// Resource that published the release.
    var resourceID: Resource.IDValue

    enum CodingKeys: String, CodingKey {
      case version, month, year, resourceID
    }

    static let example = Create(
      version: "1.0.0",
      month: 7,
      year: 2026,
      resourceID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
    )

    /// Validates and converts the request into an unsaved Fluent model.
    func toModel() throws -> Release {
      let model = Release()
      model.version = try requireNonBlank(version, "version")
      model.$resource.id = resourceID

      model.releasedAt = try requireCalendarDate(
        year: requireInRange(year, supportedYears, "year"),
        month: requireInRange(month, 1...12, "month"),
        "releasedAt",
      )
      return model
    }
  }

  /// Partial request body for correcting a recorded release.
  struct Update: Content, WithExample {
    /// Human-readable release or version identifier.
    var version: String?
    /// One-based release month, required together with `year` when either is supplied.
    var month: Int?
    /// Four-digit release year supported by the API.
    var year: Int?

    enum CodingKeys: String, CodingKey {
      case version, month, year
    }

    static let example = Update(version: "1.0.1", month: 8, year: 2026)
  }

  /// Public release representation returned by the API.
  struct Public: Content {
    var id: UUID?
    /// Resource that published the release.
    var resourceID: Resource.IDValue?
    /// Human-readable release or version identifier.
    var version: String?
    /// Normalized release date at midnight UTC.
    var releasedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, resourceID, version, releasedAt
    }
  }

  /// Projects loaded model fields into the public API shape.
  func toPublic() -> Public {
    .init(
      id: id,
      resourceID: $resource.id,
      version: $version.value,
      releasedAt: releasedAt,
    )
  }
}
