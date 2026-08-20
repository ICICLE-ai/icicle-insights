import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A named version published for a resource at a calendar date.
final class Release: Model, @unchecked Sendable {
  static let schema = "releases"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "resource_id")
  /// Resource that published this release.
  var resource: Resource

  @Field(key: "version")
  /// Human-readable version or release identifier.
  var version: String

  @Timestamp(key: "released_at", on: .none)
  /// Normalized calendar date on which the version was published.
  var releasedAt: Date?

  init() {}

  /// Creates a release associated with an existing resource.
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
