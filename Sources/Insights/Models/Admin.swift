import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A Tapis username granted administrative access to Insights.
///
/// Deliberately *not* derived from Tapis's own `admin_user` or Security Kernel roles. Those say
/// who administers the Tapis tenant, which is a different question from who may mutate ICICLE's
/// metrics — coupling them would let a TACC-level role change grant or revoke dashboard access
/// for unrelated reasons.
///
/// The root admin from `ROOT_ADMIN_USERNAME` is never stored here. It is always an admin, so an
/// emptied table can never lock the deployment owner out.
final class Admin: Model, @unchecked Sendable {
  static let schema = "admins"

  @ID(key: .id)
  var id: UUID?

  @Field(key: "username")
  /// Tapis `tapis/username` claim — the bare username, not the `user@tenant` form `sub` carries.
  var username: String

  @Field(key: "added_by")
  /// Whoever granted this access, for the audit trail.
  var addedBy: String

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  /// Soft delete, so removing someone leaves a record that they once had access.
  @Timestamp(key: "deleted_at", on: .delete)
  var deletedAt: Date?

  init() {}

  init(id: UUID? = nil, username: String, addedBy: String) {
    self.id = id
    self.username = username
    self.addedBy = addedBy
  }
}
