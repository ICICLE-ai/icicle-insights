/// Wraps sensitive text and redacts it from descriptions, debug output, and reflection.
struct Secret: Sendable,
  CustomStringConvertible,
  CustomDebugStringConvertible,
  CustomReflectable
{
  private let value: String

  /// Creates a redacted wrapper around a secret value.
  init(_ value: String) {
    self.value = value
  }

  /// Returns the underlying value for an authenticated outbound request.
  /// - Warning: Keep the returned string out of logs, errors, and persisted configuration.
  func getSecretValue() -> String {
    value
  }

  /// A permanently redacted printable representation.
  var description: String {
    "«redacted»"
  }

  /// A permanently redacted debugger representation.
  var debugDescription: String {
    "«redacted»"
  }

  /// A mirror that prevents reflection tools from revealing the wrapped value.
  var customMirror: Mirror {
    Mirror(reflecting: "«redacted»")
  }
}
