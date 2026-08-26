import Queues

/// Every named queue this service runs, kept in one file so "which queues exist" has a single
/// answer rather than being inferred from whichever job happens to name one.
extension QueueName {
  /// Drained by `queues --queue metrics`. Off `.default` so a sweep's backlog cannot starve
  /// unrelated work queued behind it.
  static let metrics = QueueName(string: "metrics")
}
