import Queues

import func Foundation.pow

/// Retry budget every sync job is dispatched with.
///
/// Three attempts after the first covers the failures that clear on their own — a throttled
/// window, a restarting upstream — without keeping a permanently broken resource in the queue for
/// the better part of an hour.
let syncJobMaxRetryCount = 3

/// Exponential backoff for jobs whose failures are remote rather than local.
///
/// `Job`'s own default returns `0`, which requeues immediately: three attempts against a
/// rate-limited API then all land inside the same second and fail identically. Every job here
/// talks to an external platform, so the useful question is never "again now?" but "again later".
protocol BackoffRetrying: Job {}

extension BackoffRetrying {
  /// 30s, 2m, then 8m. `attempt` is 1-based on the first retry.
  ///
  /// Quadrupling rather than doubling because the shortest GitHub throttle worth waiting out is
  /// minutes, not seconds; the whole budget still finishes inside the hourly sweep interval, so a
  /// resource is never retrying and being re-dispatched at the same time.
  func nextRetryIn(attempt: Int) -> Int {
    30 * Int(pow(4.0, Double(attempt - 1)))
  }
}
