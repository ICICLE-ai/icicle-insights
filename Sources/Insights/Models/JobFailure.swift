import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// A collection job that exhausted its retry budget.
///
/// Logging and Slack remain the immediate notification paths. This row is the durable operational
/// history the admin console can query after logs have rotated or an alert channel was missed.
final class JobFailure: Model, @unchecked Sendable {
  static let schema = "job_failures"

  @ID(key: .id)
  var id: UUID?

  @OptionalParent(key: "resource_id")
  var resource: Resource?

  @OptionalParent(key: "account_id")
  var account: Account?

  @Field(key: "job")
  var job: String

  @Field(key: "subject")
  var subject: String

  @Field(key: "identifier")
  var identifier: String

  @Field(key: "details")
  var details: String

  @Field(key: "severity")
  var severity: String

  @Field(key: "failed_at")
  var failedAt: Date

  init() {}

  init(
    id: UUID? = nil,
    resourceID: Resource.IDValue? = nil,
    accountID: Account.IDValue? = nil,
    job: String,
    subject: String,
    identifier: String,
    details: String,
    severity: String,
    failedAt: Date = Date(),
  ) {
    self.id = id
    $resource.id = resourceID
    $account.id = accountID
    self.job = job
    self.subject = subject
    self.identifier = identifier
    self.details = details
    self.severity = severity
    self.failedAt = failedAt
  }
}
