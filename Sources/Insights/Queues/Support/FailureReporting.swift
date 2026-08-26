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

  /// Reports a resource sync that has exhausted its retries, and re-books it so the failure costs
  /// hours rather than the interval `CollectDueResources` already advanced it by at dispatch.
  /// Credential failures retry hourly until the token is repaired; everything else backs off on
  /// `CollectionSchedule`'s capped curve.
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

    guard let resource else { return }

    let now = Date()
    let retryAt: Date
    if error.isCredentialFailure {
      // Flat, and deliberately not escalating: the fix lands out of band and can land at any
      // moment, so there is no point spacing attempts out. See `credentialRetryInterval`.
      retryAt = now.addingTimeInterval(credentialRetryInterval)
    } else {
      // Everything else used to fall out here without re-booking, which meant the sweep's
      // dispatch-time advance stood: one failure cost a full interval, two put a GitHub resource
      // past its 14-day traffic window, and the days in between were gone for good.
      let overdue = CollectionSchedule.overdue(
        now: now,
        lastSuccess: resource.lastCollectedAt,
        createdAt: resource.createdAt,
        intervalDays: resource.collectionIntervalDays,
      )
      retryAt = now.addingTimeInterval(CollectionSchedule.retryDelay(overdueBy: overdue))
    }

    await noteRetentionWindowBreach(
      resource, now: now, job: job, subject: subject ?? resourceID.uuidString, metadata: metadata)

    resource.nextCollectionAt = retryAt
    do {
      try await resource.save(on: application.db)
      logger.notice(
        "Resource re-booked after a failed collection",
        metadata: metadata.merging(["retry_at": .string("\(retryAt)")]) { _, new in new }
      )
    } catch {
      // The alert has already gone out, so the operator still knows. Losing the rebooking only
      // costs the automatic recovery, which is why this is reported rather than retried.
      logger.error(
        "Could not re-book the resource after a failed collection",
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
    await persistFailure(
      job: job,
      subject: subject,
      identifier: error.alertIdentifier,
      details: error.alertDetails,
      severity: error.isCredentialFailure ? "critical" : "warning",
      resourceID: resourceID,
      accountID: accountID,
    )
  }

  /// Persists one row of operational history from values rather than an error.
  ///
  /// The retention-window breach is a condition, not a thrown error — there is no `Error` to
  /// classify — but it belongs in the same history the admin console reads.
  ///
  /// This must never throw. QueueWorker awaits the job's error callback before clearing the job;
  /// propagating a database failure from here strands the failed job and can stop the worker.
  private func persistFailure(
    job: String,
    subject: String,
    identifier: String,
    details: String,
    severity: String,
    resourceID: UUID? = nil,
    accountID: UUID? = nil
  ) async {
    let failure = JobFailure(
      resourceID: resourceID,
      accountID: accountID,
      job: job,
      subject: subject,
      identifier: identifier,
      details: details,
      severity: severity
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

  /// Alerts, once per outage, when a resource's gap since its last success has passed the window
  /// its provider still serves.
  ///
  /// This is the only place that reports data as *lost* rather than delayed. Every other failure
  /// says an attempt did not work; this one says the days in the gap are no longer obtainable
  /// from the provider and no watermark can reconstruct them.
  ///
  /// Mutates `stallNotifiedAt` on the passed resource without saving — the caller saves once,
  /// with the re-booking, so a breach and its backoff land in the same write.
  private func noteRetentionWindowBreach(
    _ resource: Resource,
    now: Date,
    job: String,
    subject: String,
    metadata: Logger.Metadata
  ) async {
    // Nil means the platform cannot lose data to a window at all — the Hub reports its lifetime
    // total outright, so a late sweep costs series density and nothing permanent.
    guard let windowDays = resource.account.platform.retentionWindowDays,
      resource.stallNotifiedAt == nil
    else { return }

    let anchor = resource.lastCollectedAt ?? resource.createdAt ?? now
    let gap = now.timeIntervalSince(anchor)
    guard gap > Double(windowDays) * 86_400 else { return }

    let gapDays = Int(gap / 86_400)
    let details = """
      No collection has succeeded for \(gapDays) days, past the \(windowDays)-day window \
      \(resource.account.platform.rawValue) still serves. Daily values older than that window are \
      no longer returned and cannot be recovered — the all-time total for this resource is now \
      permanently short by the days in the gap.
      Check this account's token and the platform's status. Collection resumes on its own once a \
      sweep succeeds; the missing days will not come back.
      """

    logger.critical(
      "Collection gap has passed the provider's retention window",
      metadata: metadata.merging([
        "gap_days": .string("\(gapDays)"), "window_days": .string("\(windowDays)"),
      ]) { _, new in new }
    )
    await application.notifier.notify(
      FailureAlert(
        severity: .critical,
        job: job,
        subject: subject,
        identifier: "collection_window_exceeded",
        details: details,
      ))
    await persistFailure(
      job: job,
      subject: subject,
      identifier: "collection_window_exceeded",
      details: details,
      severity: "critical",
      resourceID: resource.id,
      accountID: resource.$account.id,
    )

    resource.stallNotifiedAt = now
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
