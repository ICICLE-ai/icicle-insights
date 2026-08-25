# ADR 008: Bounded backoff for failed collections

**Status:** Accepted

An exhausted non-credential failure re-books its resource on a capped backoff — a quarter of the
time it is overdue, clamped to 1–12 hours — instead of leaving the full-interval due date the sweep
set at dispatch. `Resource.lastCollectedAt` records the last success, and the backoff is measured
from it rather than from the last attempt, which would reset the escalation on every tick.

The dispatch-time advance stays. Read as a lease it is correct, and moving scheduling authority to
the job would strand the platforms that have no collector — `ghcr`, `npm` and `pypi` are dispatched
as no-ops and would never report an outcome to settle on. The defect was never the lease; it was
that nothing shortened it when the outcome turned out badly, so gaps compounded geometrically while
the provider's retention window stayed fixed.

The ceiling is load-bearing. Twelve hours sits far inside `retentionWindowDays -
maxCollectionIntervalDays`, which is why GitHub's accepted cadence dropped to 7: at 14 the cadence
equalled the window and there was no headroom for any delay, failure or not. With that margin the
policy can never be the cause of a lost day; only an outage longer than the window itself can be,
and `collection_window_exceeded` reports exactly that, once per outage.

Hugging Face is exempt from the guard. The Hub reports `downloadsAllTime` and `Metric.setAllTime`
assigns it, so a late sweep costs series density and nothing permanent. Only GitHub's watermark-
folded `clones` and `views` accumulate day by day and can age out.

#icicle-insights# #Explanation# #Developer# #decisions# #collection#
