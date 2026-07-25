/// A string wrapper that never renders its value in string conversions.
///
/// Modeled on pydantic-settings' `SecretStr`: read `rawValue` only at the point of use
/// (e.g. building an auth header); any `print`/`"\(secret)"`/logging shows `«redacted»`
/// so credentials can't leak into logs.
struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String {
        "«redacted»"
    }

    var debugDescription: String {
        "«redacted»"
    }
}
