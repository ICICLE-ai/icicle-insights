# ADR 004: Watermarks guard all-time totals

**Status:** Accepted

## Context

GitHub's traffic endpoints return a rolling 14-day window rather than a delta since the last visit.
Consecutive sweeps overlap heavily. Adding each response to a running total counts the shared days
repeatedly; at a daily cadence a single day could be counted about fourteen times.

The queue is at-least-once, so a retry can deliver the same response again.

## Decision

Keep one `metric_watermarks` row per `(resource, metric type)` recording the newest completed UTC
day already folded into the all-time total.

Fold a day only when it is newer than the watermark **and** older than today's UTC midnight.

## Consequences

Re-running a sweep adds nothing new, so retries and forced collections are safe by construction.
This is what makes an at-least-once queue acceptable for counting.

Excluding the current day means a figure lags by up to a day. Including it would be worse: banking
a partial day records a low number *and* advances the watermark past that day, so the remainder is
never counted.

The watermark is kept separate from the collection due date. They answer different questions —
what has been counted, versus when to fetch next — and keeping them apart is what lets a late sweep
resume exactly where the last one stopped.

Folding is a read-modify-write, so it takes a transaction-scoped PostgreSQL advisory lock keyed on
the pair. FluentKit has no row locking in this version.

A watermark cannot recover data the provider no longer returns. Collection intervals must stay
inside each platform's retention window, and that cap is enforced when a resource is created.

Gauges keep no all-time row at all. The series is the record.

#icicle-insights# #Explanation# #Developer# #decisions# #data-integrity#
