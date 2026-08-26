import Queues
import Redis

import struct Foundation.Date
import typealias Foundation.TimeInterval

/// Redis marker updated by every scheduled job before it does any other work.
///
/// It deliberately survives with no expiry: the admin endpoint needs to distinguish "never
/// observed" from "last observed three days ago". Age is evaluated when it is read.
enum SchedulerHeartbeat {
  static let redisKey = "insights:scheduler:last-run"
  static let staleAfter: TimeInterval = 2 * 60 * 60
}

extension QueueContext {
  /// Records scheduler liveness without ever preventing the scheduled job from running.
  func recordSchedulerHeartbeat(job: String, at date: Date = Date()) async {
    do {
      try await application.redis
        .set(RedisKey(SchedulerHeartbeat.redisKey), to: String(date.timeIntervalSince1970))
        .get()
    } catch {
      logger.warning(
        "Could not record scheduler heartbeat; continuing scheduled work.",
        metadata: ["job": .string(job), "error": .string(String(reflecting: error))]
      )
    }
  }
}
