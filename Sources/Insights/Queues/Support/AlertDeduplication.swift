import Queues
import Redis
import Vapor

import typealias Foundation.TimeInterval

/// How long one exhausted-job alert holds back the next with the same identifier and severity.
///
/// Six hours, because the failure this exists for repeats hourly. An expired `TAPIS_TOKEN` fails
/// every resource at once, and each re-books an hour out, so undeduplicated it was about 110
/// critical Slack messages an hour until someone renewed the token. That is how a channel gets
/// muted, and a muted channel hides the next real failure too.
///
/// An hour was rejected because it only merges the resources failing in one sweep: an outage
/// still alerted every hour, all night. A day was rejected because it is too quiet. A failure
/// that starts overnight would not repeat until the next night, and a second, unrelated problem
/// that happens to share an identifier would be hidden for just as long. Six hours repeats
/// about once per working half-day for as long as the fault lasts.
enum AlertDeduplication {
  static let window: TimeInterval = 6 * 3600
}

extension Application {
  private struct AlertDedupeKeyPrefixKey: StorageKey {
    typealias Value = String
  }

  /// Prefix of the Valkey keys that record which alerts were recently sent.
  ///
  /// Shared by every worker on purpose: the same failure lands on whichever worker ran the job,
  /// so a per-process memory would let each replica send its own copy. Replaceable because the
  /// test suite shares its Valkey with local development, and each test needs a namespace of its
  /// own or one test's alert would suppress the next test's.
  var alertDedupeKeyPrefix: String {
    get { storage[AlertDedupeKeyPrefixKey.self] ?? "insights:alerts:sent" }
    set { storage[AlertDedupeKeyPrefixKey.self] = newValue }
  }
}

extension QueueContext {
  /// Claims the right to send an alert, answering false when one with the same identifier and
  /// severity already went out within ``AlertDeduplication/window``.
  ///
  /// One `SET key NX EX`, so the check and the claim are a single atomic step: two workers
  /// failing the same way in the same second cannot both see "not sent yet".
  ///
  /// **Fails open.** If Valkey cannot answer, the alert is sent. A duplicate costs a little
  /// noise; a suppressed alert about a real outage costs the outage going unnoticed. Valkey
  /// being down is also exactly when the queue itself is struggling and someone should hear.
  func claimAlert(identifier: String, severity: AlertSeverity) async -> Bool {
    let level =
      switch severity {
      case .critical: "critical"
      case .warning: "warning"
      }
    let key = RedisKey("\(application.alertDedupeKeyPrefix):\(level):\(identifier)")

    do {
      let result = try await application.redis.set(
        key,
        to: "1",
        onCondition: .keyDoesNotExist,
        expiration: .seconds(Int(AlertDeduplication.window)),
      ).get()
      return result == .ok
    } catch {
      logger.warning(
        "Alert deduplication unavailable; sending the alert anyway.",
        metadata: [
          "identifier": .string(identifier),
          "error": .string(String(reflecting: error)),
        ]
      )
      return true
    }
  }
}
