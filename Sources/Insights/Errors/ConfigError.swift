import Foundation

/// Startup/configuration failures — thrown when required environment is missing so the app
/// fails fast at boot rather than on first use.
enum ConfigError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let name):
            "Missing required environment variable \(name)"
        }
    }
}
