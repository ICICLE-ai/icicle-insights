import Fluent
import Vapor
import VaporToOpenAPI

extension Release {
    struct Create: Content, WithExample {
        var version: String
        var month: Int
        var year: Int
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

        func toModel() throws -> Release {
            let model = Release()
            model.version = try requireNonBlank(version, "version")
            model.$resource.id = resourceID

            model.releasedAt = try requireCalendarDate(
                year: requireInRange(year, supportedYears, "year"),
                month: requireInRange(month, 1 ... 12, "month"),
                "releasedAt",
            )
            return model
        }
    }

    struct Public: Content {
        var id: UUID?
        var resourceID: Resource.IDValue?
        var version: String?
        var releasedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, resourceID, version, releasedAt
        }
    }

    func toPublic() -> Public {
        .init(
            id: id,
            resourceID: $resource.id,
            version: $version.value,
            releasedAt: releasedAt,
        )
    }
}
