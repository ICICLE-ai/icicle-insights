/// How loudly a collection failure should be announced.
///
/// Two levels rather than a full ladder, because only one distinction changes what an operator
/// does: either a credential needs repairing by hand, or the platform misbehaved and collection
/// will resume without anyone.
enum AlertSeverity: Sendable {
  case critical
  case warning
}

/// One collection failure, already reduced to the parts an alert channel can render.
///
/// Carries strings rather than the originating error so the type stays `Sendable` and so the
/// wording is decided by the job that has the context, not by the transport.
struct FailureAlert: Sendable {
  let severity: AlertSeverity
  /// The job that gave up, e.g. `SyncGitHubRepoStats`.
  let job: String
  /// What it was collecting, in the form an operator recognizes, e.g. `icicle-ai/insights`.
  let subject: String
  /// `JobError.identifier`, so an alert and its log line can be tied together.
  let identifier: String
  /// The full explanation, including any suggested fixes.
  let details: String
}

/// An outbound channel for collection failures that need a human.
///
/// Deliberately provider-neutral, matching ``SecretProvider``: jobs describe the failure and the
/// installed implementation decides where it goes.
///
/// `notify` is `async` but **not** `throws`, and that is load-bearing rather than an oversight.
/// `QueueWorker.runOneJob` awaits `job._error(...)` with `try` *before* it clears the job from the
/// queue, so an alert that threw would strand the job and break the worker's run loop. A channel
/// that cannot be reached must degrade to a log line, never to a stuck queue.
protocol FailureNotifier: Sendable {
  func notify(_ alert: FailureAlert) async
}

/// The notifier installed when no webhook is configured.
///
/// Alerting is optional in a way credentials are not, so an unconfigured deployment — every test
/// run, and any local `swift run` — stays silent instead of failing to boot.
struct NoopNotifier: FailureNotifier {
  func notify(_ alert: FailureAlert) async {}
}
