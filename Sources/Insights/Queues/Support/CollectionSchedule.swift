import struct Foundation.Date
import typealias Foundation.TimeInterval

/// When to try a resource again after a collection failed.
///
/// Kept apart from the failure reporter so the curve can be tested as arithmetic, without a
/// `QueueContext` or a database, and so the one place that decides "how long until the next
/// attempt" is findable by name.
///
/// The shape of the curve matters less than its ceiling. `CollectDueResources` advances a
/// resource's due date when it *dispatches*, so before this existed a failed collection cost a
/// full interval and gaps between successes compounded while the provider's retention window did
/// not. Anything that re-books inside the window fixes that; the curve just decides how much
/// noise the fix makes on the way.
enum CollectionSchedule {
  /// Never sooner than the sweep that would pick it up anyway — `CollectDueResources` runs
  /// hourly, so a shorter delay only waits for the same tick.
  static let minimumRetry: TimeInterval = 3600

  /// Never later than this, whatever the arithmetic says.
  ///
  /// Twelve hours is far inside `retentionWindowDays - maxCollectionIntervalDays`, which is seven
  /// days at GitHub's cap. That margin is the point: the policy must never be the reason a day
  /// ages out. Only an outage longer than the window itself can do that, and the data-loss alert
  /// exists to say so when it happens.
  static let maximumRetry: TimeInterval = 12 * 3600

  /// How far past its due date this resource is, measured from its last *success*.
  ///
  /// The last attempt is the wrong anchor: attempts happen on every backoff tick, so measuring
  /// from one would reset the escalation each time and hold the resource at the minimum forever.
  ///
  /// - Parameters:
  ///   - now: The current instant.
  ///   - lastSuccess: When collection last succeeded, or nil if it never has.
  ///   - createdAt: Fallback anchor for a resource with no successful collection yet.
  ///   - intervalDays: The resource's configured cadence.
  /// - Returns: Seconds past due; negative when the resource is not due yet.
  static func overdue(
    now: Date,
    lastSuccess: Date?,
    createdAt: Date?,
    intervalDays: Int
  ) -> TimeInterval {
    let anchor = lastSuccess ?? createdAt ?? now
    return now.timeIntervalSince(anchor) - Double(intervalDays) * 86_400
  }

  /// How long to wait before the next attempt.
  ///
  /// A quarter of the overdue time, clamped. Front-loaded on purpose: early attempts can still
  /// recover every day in the window, so they are worth making often, while attempts made after
  /// days of failure are recovering less and less and are not worth alerting about as often.
  /// Retries stay hourly for roughly the first four hours and reach the ceiling after about two
  /// days.
  ///
  /// - Parameter overdue: Seconds past due, from ``overdue(now:lastSuccess:createdAt:intervalDays:)``.
  /// - Returns: Seconds to wait, always between ``minimumRetry`` and ``maximumRetry``.
  static func retryDelay(overdueBy overdue: TimeInterval) -> TimeInterval {
    min(max(overdue / 4, minimumRetry), maximumRetry)
  }
}
