import Fluent
import Foundation
import SQLKit

extension Metric {
  /// Serializes concurrent read-modify-writes of one resource's all-time total.
  ///
  /// The fold is a read-modify-write, and FluentKit exposes no row locking — nor would a row
  /// lock cover the first sweep, where no total row exists yet. `hashtext` rather than Swift's
  /// `hashValue`, which is seeded per process and so differs across workers.
  ///
  /// Keyed on the *base* type so that an API write and a sweep folding the same series contend
  /// on the same lock. Callers must already be inside a transaction; the lock is held to its
  /// end.
  private static func lockAllTime(
    on db: any Database,
    resourceID: Resource.IDValue,
    type: MetricType
  ) async throws {
    guard let sql = db as? any SQLDatabase else { return }
    try await sql.raw(
      "SELECT pg_advisory_xact_lock(hashtext(\(bind: "\(resourceID):\(type.rawValue)")))"
    ).run()
  }

  /// Applies a signed delta to the all-time total. Assumes the caller holds the lock above.
  private static func applyAllTimeDelta(
    on db: any Database,
    resourceID: Resource.IDValue,
    allTimeType: MetricType,
    delta: Double
  ) async throws {
    guard
      let total = try await Metric.query(on: db)
        .filter(\.$resource.$id == resourceID)
        .filter(\.$type == allTimeType)
        .first()
    else {
      // A missing row is created only for a positive delta: subtracting from a total that was
      // never accumulated would invent a negative one out of nothing.
      guard delta > 0 else { return }
      try await Metric(resourceID: resourceID, reading: delta, type: allTimeType).create(on: db)
      return
    }

    // Floors at zero. `reading` is validated nonnegative everywhere it enters, so a total driven
    // below zero means the deltas disagree with history — a lifetime count of -40 is not a
    // number any caller can interpret, and clamping keeps the series readable while it is fixed.
    total.reading = max(0, total.reading + delta)
    try await total.save(on: db)
  }

  /// Folds `reading` into the resource's running all-time total, creating the row on first
  /// sight. Does nothing for metrics that have no all-time counterpart.
  ///
  /// Only safe for genuine deltas. Rolling-window readings must use `foldDailyIntoAllTime`.
  ///
  /// Takes no lock of its own: every caller reaches it from inside `foldDailyIntoAllTime`'s
  /// transaction, which already holds one.
  static func addToAllTime(
    on db: any Database,
    resourceID: Resource.IDValue,
    type: MetricType,
    reading: Double
  ) async throws {
    guard let allTimeType = type.allTime else { return }
    try await applyAllTimeDelta(
      on: db, resourceID: resourceID, allTimeType: allTimeType, delta: reading)
  }

  /// Applies a signed delta to the resource's all-time total, under its own lock.
  ///
  /// The correction path for a hand-recorded reading: creating one adds it, editing one applies
  /// the difference, deleting one subtracts it. Does nothing for metrics with no all-time
  /// counterpart.
  ///
  /// Unlike `addToAllTime` this opens its own transaction, because API writes arrive outside
  /// any sweep. It takes the same lock `foldDailyIntoAllTime` does, so a request and a
  /// concurrent sweep serialize rather than racing to read-modify-write the same row.
  static func adjustAllTime(
    on db: any Database,
    resourceID: Resource.IDValue,
    type: MetricType,
    delta: Double
  ) async throws {
    guard let allTimeType = type.allTime, delta != 0 else { return }

    try await db.transaction { db in
      try await lockAllTime(on: db, resourceID: resourceID, type: type)
      try await applyAllTimeDelta(
        on: db, resourceID: resourceID, allTimeType: allTimeType, delta: delta)
    }
  }

  /// Replaces the all-time total outright, for platforms that report the lifetime figure
  /// themselves. Nothing is accumulated, so re-running a sweep is harmless.
  static func setAllTime(
    on db: any Database,
    resourceID: Resource.IDValue,
    type: MetricType,
    reading: Double
  ) async throws {
    guard let allTimeType = type.allTime else { return }

    guard
      let total = try await Metric.query(on: db)
        .filter(\.$resource.$id == resourceID)
        .filter(\.$type == allTimeType)
        .first()
    else {
      try await Metric(resourceID: resourceID, reading: reading, type: allTimeType).create(on: db)
      return
    }

    total.reading = reading
    try await total.save(on: db)
  }

  /// Folds a rolling window's per-day readings into the all-time total, counting each day
  /// exactly once across sweeps.
  ///
  /// Days at or before the watermark are already counted. Today is excluded because it is
  /// still accruing — banking it now would record a partial figure and then skip the rest,
  /// since the watermark would have moved past it.
  ///
  /// Days that age out of the platform's retention window before a sweep runs are lost;
  /// neither endpoint offers backfill. `Platform.maxCollectionIntervalDays` bounds that.
  static func foldDailyIntoAllTime(
    on db: any Database,
    resourceID: Resource.IDValue,
    type: MetricType,
    days: [TrafficDay],
    now: Date = Date()
  ) async throws {
    guard type.allTime != nil else { return }

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = utc.startOfDay(for: now)

    try await db.transaction { db in
      try await lockAllTime(on: db, resourceID: resourceID, type: type)

      let watermark = try await MetricWatermark.query(on: db)
        .filter(\.$resource.$id == resourceID)
        .filter(\.$type == type)
        .first()

      let countedThrough = watermark?.countedThrough
      let fresh = days.filter { day in
        guard day.timestamp < today else { return false }
        guard let countedThrough else { return true }
        return day.timestamp > countedThrough
      }

      guard let newest = fresh.map(\.timestamp).max() else { return }

      try await addToAllTime(
        on: db,
        resourceID: resourceID,
        type: type,
        reading: fresh.reduce(0.0) { $0 + Double($1.count) }
      )

      if let watermark {
        watermark.countedThrough = newest
        try await watermark.save(on: db)
      } else {
        try await MetricWatermark(
          resourceID: resourceID,
          type: type,
          countedThrough: newest
        ).create(on: db)
      }
    }
  }
}
