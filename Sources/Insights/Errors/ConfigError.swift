import Foundation

/// A startup failure caused by missing or unsupported configuration.
enum ConfigError: Error, CustomStringConvertible {
  case missing(String)
  case unsupported(name: String, value: String)

  /// A safe diagnostic identifying the missing key without exposing any secret value.
  var description: String {
    switch self {
    case .missing(let name):
      "Missing required environment variable \(name)"
    case .unsupported(let name, let value):
      "Unsupported \(name) value: \(value)"
    }
  }
}
