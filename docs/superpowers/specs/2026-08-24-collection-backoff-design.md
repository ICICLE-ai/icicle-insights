# Bounded backoff for failed collections

**Status:** Approved, not yet implemented
**Date:** 2026-08-24

Failed collections currently cost a full collection interval each. Gaps between *successful*
collections compound without bound while the provider's retention window does not, so rolling-window
days age out and are lost permanently. This replaces the missing failure policy with a bounded
backoff, and adds the alert that says when data has actually been lost.

## The defect

`CollectDueResources` advances `nextCollectionAt` at dispatch time, as soon as the enqueue succeeds
([CollectDueResources.swift:39](../../../Sources/Insights/Queues/Scheduled/CollectDueResources.swift)). A job
that later fails writes nothing — `metrics.create` and both folds run only after all three GitHub
fetches succeed — so `MetricWatermark.countedThrough` stays where it was while the due date has
already jumped a full interval.

Only credential failures are corrected, by the +1h re-booking in `reportResourceSyncFailure`
([Support/FailureReporting.swift:64](../../../Sources/Insights/Queues/Support/FailureReporting.swift)). Every other
failure — 5xx, 429, `decodingFailed` — gets no re-booking at all.

At the default 7-day interval:

| Day | Outcome | Due date | Watermark |
|---|---|---|---|
| 0 | success | 7 | day 0 |
| 7 | fails (non-credential) | 14 | day 0 |
| 14 | fails | 21 | day 0 |
| 21 | success — response covers days 7–21 | 28 | day 20 |

Days 1–6 appear in no successfully folded response and cannot be reconstructed. This violates the
invariant that collection intervals must not exceed provider retention windows. Two consecutive
failures at the default interval are enough.

## What the investigation found

**Hugging Face is not exposed.** `SyncHuggingFaceHubStats` stores `downloadsAllTime` through
`Metric.setAllTime` — a lifetime figure the Hub reports directly
([Collectors/SyncHuggingFaceHubStats.swift:72](../../../Sources/Insights/Queues/Collectors/SyncHuggingFaceHubStats.swift)).
A missed sweep costs trend-series density, never all-time correctness. Only GitHub's watermark-folded
`clones` and `views` can lose days permanently. `Platform.maxCollectionIntervalDays` is therefore
doing two unrelated jobs today: a correctness deadline for GitHub, a density preference for the Hub.

**The accepted interval range has no headroom at its maximum.** `ResourceController` validates
against `1...platform.maxCollectionIntervalDays`, which is 14 for GitHub
([ResourceController.swift:69](../../../Sources/Insights/Controllers/ResourceController.swift)). At
interval 14 the sweep cadence equals the retention window exactly, so any delay at all loses days —
no backoff value can protect that configuration. The real headroom is `retention − interval`: seven
days at the default, zero at the maximum the API accepts.

**Non-collectable platforms must keep advancing.** `dispatchSync` logs and returns for `ghcr`, `npm`
and `pypi`, so nothing will ever report an outcome for them. Any rule of the form "advance only on
success" would strand them as permanently due and re-sweep them hourly forever. Pinned by
[QueueSweepTests.swift:88](../../../Tests/InsightsTests/QueueSweepTests.swift). This is the main
reason scheduling authority stays with the sweep.

**A dead worker orphans its job permanently.** `queues-redis-driver` 1.1.2 pops with `RPOPLPUSH` into
`metrics-processing` and never reclaims from that list. If a worker dies mid-job the identifier stays
there and `error(_:_:_:)` never fires, so no failure-path policy can cover the crash case. Today that
silently costs a full interval; after this change it still does. Accepted, because a single missed
interval stays inside the window once the interval cap is lowered.

## The reframing

The dispatch-time advance is not itself the defect. Read as a lease, it is defensible: the schedule
already tolerates a bounded delay. The defect is that a failure extends the lease by a *full
interval* with nothing ever pulling it back, so gaps compound geometrically while the window stays
fixed. Bounding the compounding restores the invariant without moving scheduling authority out of the
sweep, and without disturbing the skip path or any existing test.

## Design

### 1. New state

Two nullable columns on `resources`, in a new additive migration following `RecurringCollection`'s
shape.

| Column | Purpose |
|---|---|
| `last_collected_at` | Set on every successful `dequeue`. The gap between *successes* is what the retention window governs, and nothing records it today. Nullable for existing rows; gap calculations fall back to `created_at`. |
| `stall_notified_at` | When the data-loss alert last fired. Cleared on success, so the alert fires once per outage rather than on every failure afterwards. |

No `consecutive_failures` counter. Backoff derives from elapsed time instead, which is immune to a
double-dispatched failure double-incrementing it — under at-least-once delivery a counter is the less
safe choice.

### 2. Backoff policy

The policy itself lives in a new `Queues/Support/CollectionSchedule.swift` — it is shared machinery
by the taxonomy the queue reorganization established, and keeping it out of the failure reporter
makes it testable without constructing a `QueueContext`. `reportResourceSyncFailure`, in the branch
that currently returns for non-credential errors, calls it and books the result:

```
overdue = now − (lastCollectedAt ?? createdAt) − collectionInterval
retryAt = now + clamp(overdue / 4, 1 hour, 12 hours)
```

Retries stay hourly for roughly the first eight hours, stretching to the 12-hour cap after about two
days. Front-loaded where recovery still saves every day, quiet once it clearly will not. Roughly 42
alerts across a 14-day outage rather than 336.

The cap matters more than the curve: **12 hours must stay far inside `retention − interval`**, which
section 4's cap change guarantees (seven days at GitHub's new maximum). Failures then cost hours
rather than intervals, so reaching a 14-day gap requires a genuine two-week outage.

**Credential failures keep their flat +1h**, unchanged. It is a documented invariant, the fix lands
out of band and fast, and leaving it alone confines the change to the branch that has no policy today.

### 3. Where the writes happen

A helper on `Resource`, called at the end of both `dequeue` implementations after the metrics and
folds have been written:

```swift
try await resource.recordSuccessfulCollection(on: db)
```

It sets `lastCollectedAt = now`, `nextCollectionAt = now + interval`, and clears `stallNotifiedAt`.

The sweep's dispatch-time advance stays exactly as written and becomes, honestly, a lease: the
schedule now anchors on the last success, and the lease governs only what happens while an outcome is
outstanding. `entryVanished` still returns without writing — a deleted row is not a failed collection.

`save` writes the whole row, so an admin `PATCH` landing between dispatch and settle is clobbered.
`reportResourceSyncFailure` already carries that exposure; this change does not widen it, and
addressing it is out of scope.

### 4. The data-loss guard

`Platform` gains `foldsRollingWindows` — true for `.github` only, false for the Hub — in the same
switch style as the existing property, with the reason in its doc comment.

`maxCollectionIntervalDays` splits in two, because it currently conflates them:

| Property | Meaning | GitHub | Hub |
|---|---|---|---|
| `maxCollectionIntervalDays` | longest interval the API accepts | **7** (was 14) | 30 |
| `retentionWindowDays` | what the provider still returns | 14 | — |

On each exhausted failure, when the resource folds rolling windows, `now − lastCollectedAt` exceeds
`retentionWindowDays`, and `stallNotifiedAt` is nil: emit a critical alert with identifier
`collection_window_exceeded` naming the resource, the gap, and the range of traffic days now
unrecoverable; persist its own `JobFailure` row, distinct from the underlying error's, because they
are different facts; then stamp `stallNotifiedAt`.

The migration clamps any GitHub resource above interval 7 down to 7. Nothing in the repository seeds
such a row, so the clause is defensive. The revert cannot restore original values — documented as
one-way.

### 5. Verification

None of this touches Tapis, so `.testing` is not blind to it. The suite covers the change end to end
and it does not need staging validation.

New tests in `JobFailureTests`:

- a non-credential failure re-books within the cap rather than a full interval
- backoff grows with overdue time and stays within 1h–12h
- success resets `lastCollectedAt` and `nextCollectionAt` and clears `stallNotifiedAt`
- the window alert fires once and not again on the next failure
- the window alert stays silent for Hugging Face
- credential failures still book flat 1h

In `MetricAllTimeTests`: the exact scenario above — two consecutive failures at interval 7 — asserted
to keep every day inside the window.

In `ResourceControllerTests`: intervals 8–14 now rejected for GitHub, 30 still accepted for the Hub.

No existing test changes meaning. The four `QueueSweepTests` covering dispatch-time advance stay valid
as written.

### 6. Documentation

- `docs/invariants.md` — amend the two scheduling bullets
- `CLAUDE.md` — the matching invariant line
- `docs/collection.md` and `docs/watermarks.md` — scheduling sections
- `docs/decisions/005-failure-alerting.md` — amend; it explicitly rationalises the current
  dispatch-advance behaviour
- `docs/decisions/008-collection-backoff.md` — new

## Out of scope, found on the way

Recorded because they are real and undocumented, not because this change addresses them.

- **Credential failures already storm.** The +1h re-booking is unbounded, so a broken token produces
  one critical Slack message per resource per hour indefinitely. Every account shares one vault, so a
  `TAPIS_TOKEN` expiry hits all of them at once.
- **A retry after a partial `dequeue` failure duplicates series rows.** If the clones fold succeeds
  and the views fetch then fails, the retry re-creates all five `Metric` rows. The fold is idempotent
  through the watermark; the series is not, so the trend chart gains duplicate points.
- **Orphaned jobs accumulate in `metrics-processing`.** Nothing reclaims that list, so every worker
  crash leaves an entry behind permanently.
