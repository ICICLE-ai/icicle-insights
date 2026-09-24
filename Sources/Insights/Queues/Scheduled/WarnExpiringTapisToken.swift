import Queues
import Vapor

import struct Foundation.Date

/// Daily check that alerts before, and once after, `TAPIS_TOKEN` expires.
///
/// The token is a static environment variable that nothing refreshes. When it lapses, every vault
/// read fails, so collection stops for every account at once while the platforms stay healthy.
/// The failures do alert, but only after the fact and only once per six hours, so the useful
/// warning is the one that arrives while there is still time to renew. Warning ahead was chosen
/// over refreshing the token automatically, which would mean holding a longer-lived credential
/// able to mint this one.
///
/// Modelled on `WarnExpiringServiceTokens`, with the same threshold mechanism: the job runs daily,
/// the token's remaining days pass through each value once, so each threshold fires once without
/// any state. Like that job it only queries and alerts, so it runs inline on the scheduler.
struct WarnExpiringTapisToken: AsyncScheduledJob {
  /// Days remaining that produce a warning, and `0` for "expired within the last day".
  ///
  /// Fewer and closer than the service-token thresholds: renewing `TAPIS_TOKEN` is an edit and a
  /// restart, not a reissue that a deployed service has to pick up, so a fortnight's notice buys
  /// nothing. `0` is how "critically once expired" stays once: `daysRemaining` rounds up, so a
  /// token that lapsed within the last 24 hours reads 0 on exactly one daily run, and older lapses
  /// read negative and are left to the collection failures that are by then alerting anyway.
  static let warnAtDaysRemaining = [7, 3, 1, 0]

  /// Reads the configured token's expiry and alerts if today is a threshold.
  func run(context: QueueContext) async throws {
    await context.recordSchedulerHeartbeat(job: "WarnExpiringTapisToken")

    // Not a JWT, or no `exp`. `configure` has already said so once at boot; repeating it daily
    // would only add noise to a deployment, such as CI, that knowingly runs without one.
    guard let expiry = context.application.tapisConfig.tokenExpiry else { return }

    await Self.warn(
      expiry: expiry,
      tenant: context.application.tapisConfig.tenant,
      now: Date(),
      context: context,
    )
  }

  /// Sends the alert for `expiry` if `now` puts it on a threshold. Separate from `run` so a test
  /// can place the expiry anywhere without waiting for a real clock.
  static func warn(expiry: Date, tenant: String, now: Date, context: QueueContext) async {
    let remaining = WarnExpiringServiceTokens.daysRemaining(from: now, to: expiry)
    guard warnAtDaysRemaining.contains(remaining) else { return }

    let expired = remaining <= 0
    let details =
      expired
      ? """
      TAPIS_TOKEN expired at \(expiry). Every vault read now fails, so no account is being \
      collected. Renew it, update it on every process, and restart; collection resumes on the \
      next hourly sweep.
      """
      : """
      TAPIS_TOKEN expires in \(remaining) day\(remaining == 1 ? "" : "s"), at \(expiry). When it \
      does, every vault read fails and collection stops for every account. Renew it before \
      then, update it on every process, and restart.
      """

    context.logger.warning(
      expired ? "Tapis service token has expired." : "Tapis service token nearing expiry.",
      metadata: [
        "tapis_tenant": .string(tenant),
        "expires_at": .string("\(expiry)"),
        "days_remaining": .stringConvertible(remaining),
      ]
    )

    await context.application.notifier.notify(
      FailureAlert(
        // Same escalation as the service-token warner: a week's notice is something to
        // schedule, three days' is something to do now.
        severity: remaining <= 3 ? .critical : .warning,
        job: "WarnExpiringTapisToken",
        subject: "TAPIS_TOKEN (\(tenant))",
        identifier: expired ? "tapisToken.expired" : "tapisToken.expiring",
        details: details,
      )
    )
  }
}
