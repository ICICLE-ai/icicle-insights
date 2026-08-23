import Fluent
import Logging
import Queues
import Vapor

import struct Foundation.Date
import typealias Foundation.TimeInterval
import struct Foundation.UUID

/// How soon a credential failure books the next attempt.
///
/// `CollectDueResources` runs hourly, so anything under an hour just waits for the same tick. The
/// point is not speed but staying in rotation: without this the resource keeps the due date the
/// sweep already advanced — `Resource.defaultCollectionIntervalDays` out — and a token fixed five
/// minutes later would not be noticed for a week.
private let credentialRetryInterval: TimeInterval = 3600

extension QueueContext {
  /// Records that the row a job was dispatched for no longer exists.
  ///
  /// Called instead of throwing, and that is the whole point. `QueueWorker` decides whether to
  /// retry from the remaining attempt count alone — there is no per-error hook, and the retry
  /// budget is fixed at dispatch, before the error exists. So a thrown error here would be retried
  /// four times across ten minutes to rediscover a row that has been deleted.
  ///
  /// Returning normally instead lets the worker clear the job on the first attempt. A deleted
  /// resource is not a failure the job can recover from; it is work that no longer needs doing.
  ///
  /// `notice`, not `debug`: the sweep dispatches from a live query, so a missing row means the
  /// queue and the database disagreed — ordinarily a resource deleted mid-flight, occasionally a
  /// payload outliving the database that produced it. Benign, but worth being able to see.
  func entryVanished(id: UUID, job: String) {
    logger.notice(
      "Skipping job: the entry it was dispatched for no longer exists.",
      metadata: ["job": .string(job), "entry": .string(id.uuidString)]
    )
  }

  /// Reports a resource sync that has exhausted its retries, and keeps a credential failure in
  /// rotation so it recovers on its own once the token is repaired.
  func reportResourceSyncFailure(_ error: any Error, job: String, resourceID: UUID) async {
    let resource = try? await Resource.query(on: application.db)
      .filter(\.$id == resourceID)
      .with(\.$account)
      .first()

    var metadata: Logger.Metadata = ["resource": .string(resourceID.uuidString)]
    if let resource {
      metadata["platform"] = .string(resource.account.platform.rawValue)
      metadata["account"] = .string(resource.account.name)
    }

    let subject = resource.map { "\($0.account.name)/\($0.name)" }
    report(error, job: job, subject: subject, metadata: metadata)
    await alert(error, job: job, subject: subject ?? resourceID.uuidString)
    await persistFailure(
      error,
      job: job,
      subject: subject ?? resourceID.uuidString,
      resourceID: resourceID,
      accountID: resource?.$account.id
    )

    guard error.isCredentialFailure, let resource else { return }

    resource.nextCollectionAt = Date().addingTimeInterval(credentialRetryInterval)
    do {
      try await resource.save(on: application.db)
      logger.notice(
        "Credential failure; resource re-booked for the next hourly sweep",
        metadata: metadata
      )
    } catch {
      // The alert has already gone out, so the operator still knows. Losing the rebooking only
      // costs the automatic recovery, which is why this is reported rather than retried.
      logger.error(
        "Could not re-book the resource after a credential failure",
        metadata: metadata.merging(["error": .string(String(reflecting: error))]) { _, new in new }
      )
    }
  }

  /// Reports an account sync that has exhausted its retries.
  ///
  /// No rebooking counterpart: `Account` carries no due date, since `CollectAccountStats` runs on
  /// a fixed monthly schedule. A credential failure here alerts and then waits for that schedule,
  /// or for an operator to run `collect-accounts` once the token is fixed.
  func reportAccountSyncFailure(_ error: any Error, job: String, accountID: UUID) async {
    let account = try? await Account.find(accountID, on: application.db)
    var metadata: Logger.Metadata = ["account": .string(accountID.uuidString)]
    if let account {
      metadata["platform"] = .string(account.platform.rawValue)
    }

    report(error, job: job, subject: account?.name, metadata: metadata)
    await alert(error, job: job, subject: account?.name ?? accountID.uuidString)
    await persistFailure(
      error,
      job: job,
      subject: account?.name ?? accountID.uuidString,
      accountID: accountID
    )
  }

  /// Logs the failure with keys a log search can filter on rather than prose it would have to
  /// match, at the severity the failure's kind warrants.
  private func report(
    _ error: any Error, job: String, subject: String?, metadata: Logger.Metadata
  ) {
    var metadata = metadata
    metadata["job"] = .string(job)
    if let subject {
      metadata["subject"] = .string(subject)
    }
    metadata["identifier"] = .string(error.alertIdentifier)

    guard error.isCredentialFailure else {
      logger.report(error: error, metadata: metadata)
      return
    }

    // Raised here rather than on the error type: `report(error:)` reads `logLevel` off a
    // `DebuggableError`, and a vault failure is an `AbortError` that would otherwise land at
    // `.warning` — the same level as a transient blip, for the one failure needing a person.
    logger.critical(.init(stringLiteral: error.failureDescription), metadata: metadata)
  }

  /// Sends the failure to the configured alert channel.
  private func alert(_ error: any Error, job: String, subject: String) async {
    await application.notifier.notify(
      FailureAlert(
        severity: error.isCredentialFailure ? .critical : .warning,
        job: job,
        subject: subject,
        identifier: error.alertIdentifier,
        details: error.alertDetails,
      ))
  }

  /// Persists operational history on a best-effort basis.
  ///
  /// This must never throw. QueueWorker awaits the job's error callback before clearing the job;
  /// propagating a database failure from here strands the failed job and can stop the worker.
  private func persistFailure(
    _ error: any Error,
    job: String,
    subject: String,
    resourceID: UUID? = nil,
    accountID: UUID? = nil
  ) async {
    let failure = JobFailure(
      resourceID: resourceID,
      accountID: accountID,
      job: job,
      subject: subject,
      identifier: error.alertIdentifier,
      details: error.alertDetails,
      severity: error.isCredentialFailure ? "critical" : "warning"
    )

    do {
      try await failure.create(on: application.db)
    } catch {
      logger.error(
        "Could not persist exhausted job failure; worker will continue.",
        metadata: [
          "job": .string(job),
          "subject": .string(subject),
          "error": .string(String(reflecting: error)),
        ]
      )
    }
  }
}

/// How the queue reads an error, kept here rather than pushed onto the error types themselves.
///
/// `TapisClientError` in particular stays exactly as the service defines it: what a vault failure
/// means to a *job* — that collection is stopped until someone acts — is the queue's concern, not
/// the Tapis adapter's, and `AbortError` already carries what the HTTP boundary needs.
extension Error {
  /// Whether a later attempt is pointless until someone repairs a credential.
  ///
  /// A job's token comes from the vault, so an expired `TAPIS_TOKEN` or a missing secret stops
  /// collection for every account at once while the platform APIs stay perfectly healthy. That
  /// counts the same as the platform rejecting the token itself.
  fileprivate var isCredentialFailure: Bool {
    if let jobError = self as? JobError {
      return jobError.isCredentialFailure
    }

    switch self as? TapisClientError {
    case .secretNotFound:
      // The reference exists locally but the value does not; only an operator reconciles that.
      return true
    case .requestFailed(let status):
      return status == .unauthorized || status == .forbidden
    case .invalidResponse, nil:
      return false
    }
  }

  /// The stable key an alert and its log line are correlated by.
  fileprivate var alertIdentifier: String {
    if let debuggable = self as? any DebuggableError {
      return debuggable.identifier
    }

    switch self as? TapisClientError {
    case .requestFailed: return "tapis_request_failed"
    case .secretNotFound: return "tapis_secret_not_found"
    case .invalidResponse: return "tapis_invalid_response"
    case nil: return "unknown"
    }
  }

  /// A one-line explanation, preferring whatever the error says about itself.
  fileprivate var failureDescription: String {
    switch self {
    case let debuggable as any DebuggableError: debuggable.reason
    case let abort as any AbortError: abort.reason
    default: String(reflecting: self)
    }
  }

  /// The alert body: the explanation, plus the one instruction that resolves it where there is one.
  fileprivate var alertDetails: String {
    let body = (self as? any DebuggableError)?.debuggableHelp(format: .long) ?? failureDescription

    guard self is TapisClientError, isCredentialFailure else { return body }

    return body
      + "\nRenew TAPIS_TOKEN or add the missing secret; collection resumes on the next sweep."
  }
}
