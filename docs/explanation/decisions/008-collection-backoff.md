# ADR 008: Bounded backoff for failed collections

**Status:** Accepted

An exhausted non-credential failure now re-books its resource on a capped backoff. The delay is a
quarter of the time the resource is overdue, clamped to between one and twelve hours. It replaces
the full-interval due date the sweep set at dispatch. `Resource.lastCollectedAt` records the last
success, and the backoff is measured from it rather than from the last attempt, which would reset
the escalation on every tick.

The dispatch-time advance stays. Read as a lease it is correct. Moving scheduling authority into
the job would strand the platforms that have no collector. `ghcr`, `npm` and `pypi` are skipped
without ever being dispatched, so they would never report an outcome to settle on. The defect was
never the lease; it was that nothing shortened it when the outcome turned out badly, so gaps
compounded geometrically while the provider's retention window stayed fixed.

The ceiling is load-bearing. Twelve hours sits far inside `retentionWindowDays -
maxCollectionIntervalDays`. That margin is why GitHub's accepted cadence dropped to 7. At 14 the
cadence equalled the window, leaving no headroom for any delay at all. With that margin the policy
can never be the cause of a lost day; only an outage longer than the window itself can be, and
`collection_window_exceeded` reports exactly that, once per outage.

Hugging Face is exempt from the guard. The Hub reports `downloadsAllTime` and `Metric.setAllTime`
assigns it, so a late sweep costs series density and nothing permanent. Only GitHub's watermark-
folded `clones` and `views` accumulate day by day and can age out.

#icicle-insights# #Explanation# #Developer# #decisions# #collection#
