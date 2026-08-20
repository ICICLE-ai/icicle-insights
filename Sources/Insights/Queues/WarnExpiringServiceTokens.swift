import Fluent
import Queues
import Vapor

import struct Foundation.Date

/// Daily sweep warning that webhook tokens are about to lapse.
///
/// Without it a token's expiry is completely silent: at 90 days the service's posts start
/// returning 401, its metrics stop arriving, and nothing surfaces the cause. The series simply
/// flatlines, which is the kind of thing noticed months later while looking at a chart.
///
/// Unlike the collection sweeps this dispatches nothing — there is no remote call to make, only a
/// query and an alert — so it runs inline on the scheduler.
struct WarnExpiringServiceTokens: AsyncScheduledJob {
  /// Days remaining that produce a warning.
  ///
  /// Fixed points rather than "anything under 14 days" so a token does not alert every single day
  /// for its final fortnight, which is how an alert channel gets muted. Each threshold fires once,
  /// because the sweep runs daily and a token's remaining days pass through each value once.
  ///
  /// Missing a day — a scheduler restart across midnight — skips that threshold rather than
  /// silencing the token; the remaining ones still fire. That is why there are four and not one.
  static let warnAtDaysRemaining = [14, 7, 3, 1]

  /// Warns for every live token whose remaining lifetime lands on a threshold today.
  func run(context: QueueContext) async throws {
    let now = Date()

    // Bounded by the widest threshold so the query stays selective; expired tokens are excluded
    // because a warning after the fact helps nobody, and revoked ones because they were retired
    // deliberately.
    guard let horizon = Self.warnAtDaysRemaining.max() else { return }
    let cutoff = now.addingTimeInterval(Double(horizon + 1) * 86_400)

    let expiring = try await ServiceToken.query(on: context.application.db)
      .filter(\.$revokedAt == nil)
      .filter(\.$expiresAt > now)
      .filter(\.$expiresAt <= cutoff)
      .with(\.$resource)
      .all()

    for token in expiring {
      let remaining = Self.daysRemaining(from: now, to: token.expiresAt)

      guard Self.warnAtDaysRemaining.contains(remaining) else { continue }

      let subject = "\(token.resource.name) (\(token.label))"
      let details = """
        The webhook token for '\(token.label)' expires in \(remaining) \
        day\(remaining == 1 ? "" : "s"), on \(token.expiresAt). When it does, that service's \
        metrics stop arriving with no further warning. Reissue with \
        `service-token issue --resource \(token.$resource.id) --label \(token.label)` and update \
        the deployment's secret; minting revokes this one automatically.
        """

      context.logger.warning(
        "Webhook token nearing expiry.",
        metadata: [
          "label": .string(token.label),
          "resource_id": .string(token.$resource.id.uuidString),
          "days_remaining": .stringConvertible(remaining),
        ]
      )

      await context.application.notifier.notify(
        FailureAlert(
          // Critical only once it is genuinely urgent. A fortnight's notice is something to
          // schedule; a day's notice is something to do now.
          severity: remaining <= 3 ? .critical : .warning,
          job: "WarnExpiringServiceTokens",
          subject: subject,
          identifier: "serviceToken.expiring",
          details: details,
        )
      )
    }
  }

  /// Whole days from `now` until `expiry`, rounded up.
  ///
  /// Rounded up so a token with 6.4 days left reports 7 and matches a threshold, rather than
  /// truncating to 6 and slipping between two of them. Thresholds are days-remaining labels, not
  /// precise instants.
  static func daysRemaining(from now: Date, to expiry: Date) -> Int {
    Int((expiry.timeIntervalSince(now) / 86_400).rounded(.up))
  }
}
