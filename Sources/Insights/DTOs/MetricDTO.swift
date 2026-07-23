import Fluent
import Vapor
import VaporToOpenAPI

extension Metric {
    struct Create: Content, WithExample {
        var reading: Double
        var type: MetricType
        var resourceID: Resource.IDValue

        enum CodingKeys: String, CodingKey {
            case reading, type, resourceID
        }

        static let example = Create(
            reading: 1234,
            type: .stars,
            resourceID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
        )

        func toModel() -> Metric {
            let model = Metric()
            model.reading = reading
            model.type = type
            model.$resource.id = resourceID
            return model
        }
    }

    struct Public: Content {
        var id: UUID?
        var resourceID: Resource.IDValue?
        var reading: Double?
        var type: MetricType?
        var recordedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, resourceID, reading, type, recordedAt
        }
    }

    func toPublic() -> Public {
        .init(
            id: id,
            resourceID: $resource.id,
            reading: $reading.value,
            type: $type.value,
            recordedAt: recordedAt,
        )
    }
}
