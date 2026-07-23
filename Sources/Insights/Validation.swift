import Vapor

/// Returns `value` if it is non-negative, otherwise aborts with `400 Bad Request`.
func requireNonNegative(_ value: Int, _ field: String) throws -> Int {
    guard value >= 0 else {
        throw Abort(.badRequest, reason: "'\(field)' must be greater than or equal to 0.")
    }
    return value
}
