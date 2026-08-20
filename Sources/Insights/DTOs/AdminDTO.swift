import Fluent
import Vapor
import VaporToOpenAPI

import struct Foundation.Date
import struct Foundation.UUID

extension Admin {
  /// Request body for granting administrative access.
  struct Create: Content, WithExample {
    /// Tapis `tapis/username` — the bare username, not the `user@tenant` form `sub` carries.
    var username: String

    enum CodingKeys: String, CodingKey {
      case username
    }

    static let example = Create(username: "cguz109")

    /// Validates and converts the request into an unsaved model.
    func toModel(addedBy: String) throws -> Admin {
      Admin(username: try requireNonBlank(username, "username"), addedBy: addedBy)
    }
  }

  /// Public admin representation.
  struct Public: Content {
    var id: UUID?
    var username: String?
    /// Who granted the access.
    var addedBy: String?
    var createdAt: Date?
    /// True for the environment-configured root admin, which has no row and cannot be removed.
    var isRoot: Bool?

    enum CodingKeys: String, CodingKey {
      case id, username, addedBy, createdAt, isRoot
    }
  }

  /// Projects loaded model fields into the public API shape.
  func toPublic() -> Public {
    .init(
      id: id,
      username: $username.value,
      addedBy: $addedBy.value,
      createdAt: createdAt,
      isRoot: false,
    )
  }
}
