import Fluent
import Foundation
import Vapor

/// Years a client may supply for a release or an expiration date. Wide enough for any real
/// value, narrow enough to catch a typo'd or defaulted year.
let supportedYears = 1970...2100

/// Validates that an integer is zero or greater.
/// - Returns: The unchanged validated value.
/// - Throws: `Abort(.badRequest)` when the value is negative.
func requireNonNegative(_ value: Int, _ field: String) throws -> Int {
  guard value >= 0 else {
    throw Abort(.badRequest, reason: "'\(field)' must be greater than or equal to 0.")
  }
  return value
}

/// Validates that a finite floating-point value is zero or greater.
/// - Returns: The unchanged validated value.
/// - Throws: `Abort(.badRequest)` when the value is negative or non-finite.
func requireNonNegative(_ value: Double, _ field: String) throws -> Double {
  guard value >= 0 else {
    throw Abort(.badRequest, reason: "'\(field)' must be greater than or equal to 0.")
  }
  return value
}

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

/// Constructs a strict UTC calendar date and rejects normalized invalid dates.
///
/// `DateComponents.isValidDate` round-trips through the calendar, which is what rejects
/// February 30 and the month-13 rollover that `Calendar.date(from:)` silently normalizes.
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
///
/// Non-constraint errors pass through unchanged, so an infrastructure failure is never presented
/// to the caller as though they had sent a conflicting request.
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
