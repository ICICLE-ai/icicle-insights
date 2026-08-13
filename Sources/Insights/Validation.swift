import Fluent
import Foundation
import Vapor

/// Years a client may supply for a release or an expiration date. Wide enough for any real
/// value, narrow enough to catch a typo'd or defaulted year.
let supportedYears = 1970...2100

/// Returns `value` if it is non-negative, otherwise aborts with `400 Bad Request`.
/// Validates that an integer is zero or greater.
/// - Returns: The unchanged validated value.
/// - Throws: `Abort(.badRequest)` when the value is negative.
func requireNonNegative(_ value: Int, _ field: String) throws -> Int {
  guard value >= 0 else {
    throw Abort(.badRequest, reason: "'\(field)' must be greater than or equal to 0.")
  }
  return value
}

/// Returns `value` if it is non-negative, otherwise aborts with `400 Bad Request`.
/// Validates that a finite floating-point value is zero or greater.
/// - Returns: The unchanged validated value.
/// - Throws: `Abort(.badRequest)` when the value is negative or non-finite.
func requireNonNegative(_ value: Double, _ field: String) throws -> Double {
  guard value >= 0 else {
    throw Abort(.badRequest, reason: "'\(field)' must be greater than or equal to 0.")
  }
  return value
}

/// Returns `value` trimmed of surrounding whitespace, or aborts with `400 Bad Request` if
/// nothing is left once trimmed.
/// Trims surrounding whitespace and rejects an empty result.
/// - Returns: The normalized, nonblank string.
/// - Throws: `Abort(.badRequest)` when no non-whitespace content remains.
func requireNonBlank(_ value: String, _ field: String) throws -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    throw Abort(.badRequest, reason: "'\(field)' must not be empty.")
  }
  return trimmed
}

/// Returns `value` if it falls inside `range`, otherwise aborts with `400 Bad Request`.
/// Validates that an integer lies inside an inclusive range.
/// - Returns: The unchanged validated value.
/// - Throws: `Abort(.badRequest)` when the value falls outside `range`.
func requireInRange(_ value: Int, _ range: ClosedRange<Int>, _ field: String) throws -> Int {
  guard range.contains(value) else {
    throw Abort(
      .badRequest,
      reason: "'\(field)' must be between \(range.lowerBound) and \(range.upperBound).",
    )
  }
  return value
}

/// Builds a date from the given components, aborting with `400 Bad Request` unless they describe
/// a real calendar date. `DateComponents.isValidDate` round-trips through the calendar, which is
/// what rejects February 30 and the month-13 rollover that `Calendar.date(from:)` allows.
/// Constructs a strict UTC calendar date and rejects normalized invalid dates.
/// - Returns: The requested date at midnight UTC.
/// - Throws: `Abort(.badRequest)` when the components do not form a real date.
func requireCalendarDate(year: Int, month: Int, day: Int = 1, _ field: String) throws -> Date {
  var components = DateComponents()
  components.calendar = Calendar(identifier: .gregorian)
  components.year = year
  components.month = month
  components.day = day

  guard components.isValidDate, let date = components.date else {
    throw Abort(.badRequest, reason: "'\(field)' is not a valid date.")
  }
  return date
}

/// Returns `date` if it is in the future, otherwise aborts with `400 Bad Request`.
/// Validates that a date is later than the current instant.
/// - Returns: The unchanged future date.
/// - Throws: `Abort(.badRequest)` when the date is now or in the past.
func requireFuture(_ date: Date, _ field: String) throws -> Date {
  guard date > Date() else {
    throw Abort(.badRequest, reason: "'\(field)' must be in the future.")
  }
  return date
}

/// Runs `operation`, translating a database constraint violation into `409 Conflict`.
///
/// FluentPostgresDriver maps the SQLSTATE 23xxx integrity-violation codes onto
/// `DatabaseError.isConstraintFailure`, so this stays driver-agnostic.
/// Converts a PostgreSQL constraint violation into an HTTP 409 response.
///
/// Non-constraint errors pass through unchanged so infrastructure failures are not presented as
/// user conflicts.
func conflictOnConstraintFailure<T>(
  _ reason: String,
  _ operation: () async throws -> T,
) async throws -> T {
  do {
    return try await operation()
  } catch let error as any DatabaseError where error.isConstraintFailure {
    throw Abort(.conflict, reason: reason)
  }
}
