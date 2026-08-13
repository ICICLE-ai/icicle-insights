import Logging
import Vapor

/// Posts collection failures to Slack incoming webhooks.
struct SlackNotifier: FailureNotifier {
  let client: any Client
  /// Webhook for failures that need someone to act.
  let criticalWebhookURL: String
  /// Webhook for failures that are merely worth knowing about. Configured separately so the
  /// noisy channel can be muted independently, but defaults to the critical one.
  let warningWebhookURL: String
  let logger: Logger

  /// Slack's incoming-webhook body. `text` is the only field a plain message needs.
  private struct Message: Content {
    let text: String
  }

  /// Delivers the alert, or logs why it could not be delivered.
  ///
  /// Every failure path here terminates in a log line. See ``FailureNotifier`` for why this must
  /// never throw: the worker clears the job from the queue only after this returns.
  func notify(_ alert: FailureAlert) async {
    let url = URI(string: webhookURL(for: alert.severity))

    do {
      let response = try await client.post(url) { request in
        try request.content.encode(Message(text: render(alert)))
      }

      // Slack answers a bad or revoked webhook with 403/404 and a one-word body. Without this
      // check a misconfigured URL looks exactly like a working one from in here.
      guard response.status == .ok else {
        logger.error(
          "Slack rejected the failure alert",
          metadata: [
            "status": .stringConvertible(response.status.code),
            "alert": .string(alert.identifier),
          ]
        )
        return
      }
    } catch {
      logger.error(
        "Could not deliver the failure alert to Slack",
        metadata: [
          "error": .string(String(reflecting: error)),
          "alert": .string(alert.identifier),
        ]
      )
    }
  }

  /// One channel until `SLACK_WEBHOOK_URL_WARNINGS` is set, two after — no code change either way.
  private func webhookURL(for severity: AlertSeverity) -> String {
    switch severity {
    case .critical: criticalWebhookURL
    case .warning: warningWebhookURL
    }
  }

  /// Severity first, so a channel carrying both kinds is still triageable at a glance.
  private func render(_ alert: FailureAlert) -> String {
    let heading =
      switch alert.severity {
      case .critical: "🔴 *CREDENTIAL* · `\(alert.job)` · \(alert.subject)"
      case .warning: "⚠️ `\(alert.job)` · \(alert.subject)"
      }

    return "\(heading)\n\(alert.details)"
  }
}

extension SlackNotifier {
  /// Builds the notifier from the environment, or falls back to silence.
  ///
  /// Alerting is optional in a way credentials are not — a developer running `swift run` should
  /// not have to own a webhook — so an unset URL logs once at boot rather than refusing to start.
  static func fromEnvironment(client: any Client, logger: Logger) -> any FailureNotifier {
    // An empty value means "not configured"; the container recipes always pass the name, so an
    // unset variable arrives as an empty string rather than as an absent one.
    guard let critical = Environment.get("SLACK_WEBHOOK_URL").flatMap({ $0.isEmpty ? nil : $0 })
    else {
      logger.notice("SLACK_WEBHOOK_URL is unset; collection failures will only be logged")
      return NoopNotifier()
    }

    let warning =
      Environment.get("SLACK_WEBHOOK_URL_WARNINGS").flatMap { $0.isEmpty ? nil : $0 } ?? critical

    return SlackNotifier(
      client: client,
      criticalWebhookURL: critical,
      warningWebhookURL: warning,
      logger: logger,
    )
  }
}
