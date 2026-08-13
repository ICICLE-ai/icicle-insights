import Vapor

extension Application {
  private struct FailureNotifierKey: StorageKey {
    typealias Value = any FailureNotifier
  }

  /// Application-scoped alert channel for collection failures that need a human.
  ///
  /// Unlike ``Application/secrets``, an unconfigured value is legitimate rather than fatal: a
  /// deployment with no webhook still collects correctly, it just reports failures to the log
  /// alone. Reading before `configure` therefore yields ``NoopNotifier`` instead of trapping.
  var notifier: any FailureNotifier {
    get { storage[FailureNotifierKey.self] ?? NoopNotifier() }
    set { storage[FailureNotifierKey.self] = newValue }
  }
}
