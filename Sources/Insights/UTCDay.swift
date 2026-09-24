import Foundation

/// UTC calendar days, as the `YYYY-MM-DD` strings the database and the insights API exchange.
///
/// One place for the conversion, because every piece of day arithmetic here has to agree on UTC:
/// GitHub stamps traffic days at UTC midnight, the fold banks completed UTC days, and a snapshot
/// written just after midnight in Ohio belongs to the UTC day it was written in, not the local
/// one. A formatter left on the process time zone would file it under yesterday.
enum UTCDay {
  /// A Gregorian calendar pinned to UTC.
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  /// The `YYYY-MM-DD` of the UTC day containing `date`.
  static func string(from date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// Midnight UTC of the day containing `date`.
  static func start(of date: Date) -> Date {
    calendar.startOfDay(for: date)
  }

  /// Parses a strict `YYYY-MM-DD` into that day's midnight UTC, or nil for anything else.
  ///
  /// Strict on shape as well as value: four, two, and two digits, so `2026-9-1` and a full
  /// timestamp are both refused rather than guessed at, and February 30 is refused rather than
  /// rolled into March the way `Calendar.date(from:)` would.
  static func parse(_ text: String) -> Date? {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else {
      return nil
    }

    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    guard components.isValidDate, let date = components.date else { return nil }
    return date
  }
}
