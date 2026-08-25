# Watermarks

Why all-time totals are not double counted. For administrators and developers.

A watermark is a bookmark. It says: *everything completed through this date is already counted.*

## The problem

GitHub's traffic endpoints do not report what changed since your last visit. They report a rolling
14-day window. Ask twice in one week and most of the days come back both times.

```text
Monday's response:    Jul 01  Jul 02  Jul 03  Jul 04
Tuesday's response:           Jul 02  Jul 03  Jul 04  Jul 05
```

Add both totals and July 2–4 are counted twice. At a daily cadence a single day could be counted
about fourteen times.

## The fix

Store the newest completed day already added. After Monday, the watermark is July 4. When
Tuesday's response arrives, only July 5 is newer, so only July 5 is added.

A day is counted only if it is:

1. **newer than the watermark** — everything at or before it is already in, and
2. **older than today's UTC midnight** — today is still accruing.

The second condition is easy to miss and expensive to get wrong. Banking a partial day records a
low figure *and* moves the watermark past that day, so the rest of it is never counted.

## Worked example

Clone counts arriving over three sweeps:

| Sweep | Days returned | Watermark before | Added | Watermark after |
|---|---|---|---|---|
| Monday | Fri `3`, Sat `4`, Sun `5`, Mon `2` | none | `12` | Sunday |
| Tuesday | Sat `4`, Sun `5`, Mon `7`, Tue `1` | Sunday | `7` | Monday |
| Tuesday, retried | same response | Monday | nothing | Monday |

Monday is excluded on Monday because the current UTC day is incomplete. It becomes eligible on
Tuesday, by which point its figure is `7` rather than the partial `2`.

The third row is the point: a retry adds nothing. That is what makes an at-least-once queue safe
for counting.

## Which metrics use one

| Shape | Example | Handling |
|---|---|---|
| Rolling window with daily values | GitHub clones and views | Fold days newer than the watermark |
| Provider reports a lifetime figure | Hugging Face downloads | Replace the total outright; no watermark |
| Current snapshot | Stars, forks, likes, followers | Store the reading; no all-time row |

Hugging Face needs no watermark because the Hub reports its own lifetime number. Assigning it is
idempotent by construction, so re-running a sweep is harmless.

A gauge keeps no all-time row because **the series is the record**. Stars can fall.

## Not the same as the schedule

Two fields answer two different questions.

| Field | Question |
|---|---|
| `nextCollectionAt` | When should this be fetched again? |
| `lastCollectedAt` | When did a collection last succeed? |
| `countedThrough` | Which completed days are already included? |

Keeping them separate is what lets a late sweep resume exactly where the last one stopped. Fuse
them and you are back to assuming sweeps land on schedule.

This is also why forcing a collection is safe. Running a job early changes *when* the platform is
asked, not *which days have been counted*.

## Concurrency

Several workers can finish overlapping sweeps at the same moment. The fold takes a
transaction-scoped PostgreSQL advisory lock keyed on `(resource, metric type)` before it reads the
watermark and updates the total. Read, check, add, and advance are atomic for that one metric,
while unrelated resources proceed in parallel.

## What a watermark cannot do

It prevents double counting. It cannot recover data the provider no longer returns.

Stop collecting for longer than GitHub's 14-day window and the missing days age out. Nothing can
backfill them from that endpoint. That is why each platform caps how far apart collections may be
— see [Collection schedule](../reference/collection-schedule.md).

#icicle-insights# #Explanation# #Administrator# #Developer# #data-integrity#
