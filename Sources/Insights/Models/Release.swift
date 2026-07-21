import Fluent
import struct Foundation.Date
import struct Foundation.UUID

final class Release: Model, @unchecked Sendable {
    static let schema = "releases"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "resource_id")
    var resource: Resource

    @Field(key: "version")
    var version: String

    @Timestamp(key: "released_at", on: .none)
    var releasedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        resourceID: Resource.IDValue,
        version: String,
        releasedAt: Date? = nil,
    ) {
        self.id = id
        $resource.id = resourceID
        self.version = version
        self.releasedAt = releasedAt
    }
}
