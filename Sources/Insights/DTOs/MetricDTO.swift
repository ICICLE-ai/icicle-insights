import Fluent
import Vapor
import VaporToOpenAPI

extension Metric {
  /// Request body for recording a resource metric.
  struct Create: Content, WithExample {
    /// Nonnegative numeric observation.
    var reading: Double
    /// Semantic kind of the observation.
    var type: MetricType
    /// Resource receiving the observation.
    var resourceID: Resource.IDValue

    enum CodingKeys: String, CodingKey {
      case reading, type, resourceID
    }

    static let example = Create(
      reading: 1234,
      type: .stars,
      resourceID: UUID(uuidString: "0ba5c0de-0000-0000-0000-000000000000")!,
    )

    /// Validates and converts the request into an unsaved Fluent model.
    func toModel() throws -> Metric {
      let model = Metric()
      model.reading = try requireNonNegative(reading, "reading")
      model.type = try requireRecordable(type)
      model.$resource.id = resourceID
      return model
    }
  }

  /// Request body for the resource-scoped webhook route.
  ///
  /// Carries no `resourceID`: the route takes it from the path, which is what a service's token
  /// is checked against. Accepting one in the body would invite a mismatch between what the
  /// caller asked for and what it is permitted to write.
  struct CreateForResource: Content, WithExample {
    /// Nonnegative numeric observation.
    var reading: Double
    /// Semantic kind of the observation.
    var type: MetricType

    enum CodingKeys: String, CodingKey {
      case reading, type
    }

    static let example = CreateForResource(reading: 1234, type: .downloads)

    /// Validates and converts the request into an unsaved Fluent model for one resource.
    func toModel(resourceID: Resource.IDValue) throws -> Metric {
      let model = Metric()
      model.reading = try requireNonNegative(reading, "reading")
      model.type = try requireRecordable(type)
      model.$resource.id = resourceID
      return model
    }
  }

  /// Partial request body for correcting a manually recorded reading.
  ///
  /// Carries no `resourceID` or `recordedAt`: moving a reading to a different resource or
  /// timestamp is indistinguishable from deleting and recreating it, and the timestamp is
  /// server-assigned everywhere else, so editing it here would be the one exception.
  struct Update: Content, WithExample {
    /// Nonnegative numeric observation.
    var reading: Double?
    /// Semantic kind of the observation.
    var type: MetricType?

    enum CodingKeys: String, CodingKey {
      case reading, type
    }

    static let example = Update(reading: 1250, type: .stars)
  }

  /// Public metric representation returned by the API.
  struct Public: Content {
    var id: UUID?
    /// Resource associated with the reading.
    var resourceID: Resource.IDValue?
    /// Recorded numeric value.
    var reading: Double?
    /// Semantic kind of the reading.
    var type: MetricType?
    /// Server-assigned observation timestamp.
    var recordedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, resourceID, reading, type, recordedAt
    }
  }

  /// Projects loaded model fields into the public API shape.
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
