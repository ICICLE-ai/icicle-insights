import Fluent
import Foundation
import SQLKit

extension Metric {
  /// Folds `reading` into the resource's running all-time total, creating the row on first
  /// sight. Does nothing for metrics that have no all-time counterpart.
  ///
  /// Only safe for genuine deltas. Rolling-window readings must use `foldDailyIntoAllTime`.
  static func addToAllTime(
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

    total.reading += reading
    try await total.save(on: db)
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
      // The fold is a read-modify-write, and FluentKit exposes no row locking — nor would a
      // row lock cover the first sweep, where no watermark row exists yet. `hashtext` rather
      // than Swift's `hashValue`, which is seeded per process and so differs across workers.
      if let sql = db as? any SQLDatabase {
        try await sql.raw(
          "SELECT pg_advisory_xact_lock(hashtext(\(bind: "\(resourceID):\(type.rawValue)")))"
        ).run()
      }

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
