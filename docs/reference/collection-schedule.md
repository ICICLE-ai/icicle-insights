# Collection schedule

What Insights collects, when, and from where. For administrators and developers.

## The three clocks

Registered in `configure.swift` and evaluated by the single `queues --scheduled` process.

| Clock | Runs | Does |
|---|---|---|
| `CollectDueResources` | Hourly, on the hour | Enqueues a sync for every resource whose next collection has passed |
| `CollectAccountStats` | Monthly, 1st at 03:00 | Enqueues a follower sync for every GitHub account |
| `WarnExpiringServiceTokens` | Daily at 07:00 | Alerts on webhook tokens nearing expiry. Writes nothing |

Times use the scheduler process's own time zone. Set `TZ` explicitly if 03:00 must mean a
particular local hour.

**The hourly clock is a scanner, not a collector.** It only picks up resources that are already
due. A resource with the default 7-day cadence is collected once a week, not hourly.

## Per platform

| Platform | Collected | Job | Cadence cap |
|---|---|---|---|
| GitHub repository | Stars, forks, subscribers, clones, views | `SyncGitHubRepoStats` | 14 days |
| GitHub account | Followers | `SyncGitHubOrgStats` | monthly, fixed |
| Hugging Face | Likes, 30-day downloads, lifetime downloads | `SyncHuggingFaceHubStats` | 30 days |
| GHCR | not collected | — | 30 days |
| npm | not collected | — | 30 days |
| PyPI | not collected | — | 30 days |

GHCR, npm, and PyPI resources can be registered, but the dispatcher logs and skips them. They are
still re-booked, so they will collect as soon as a job exists.

Routing is on the **account's platform**, not the resource's kind. Kind says what a thing is, not
which API reports on it.

The cadence cap is the platform's retention window. Days that age out before a sweep runs are gone
for good; neither GitHub nor Hugging Face offers backfill. `ResourceController.create` enforces
the cap.

## How a metric is stored

| Shape | Examples | All-time handling |
|---|---|---|
| Gauge | stars, forks, subscribers, likes, followers | None. The series is the record |
| Rolling window | GitHub clones and views | Folded through a watermark |
| Provider lifetime figure | Hugging Face lifetime downloads | Replaces the stored total outright |

A gauge keeps no all-time row because it can fall as well as rise. Rolling windows overlap between
sweeps, so they are folded day by day. See [Watermarks](../explanation/watermarks.md).

## Metric types

| Reading | All-time counterpart |
|---|---|
| `authentications` | `authenticationsAllTime` |
| `clones` | `clonesAllTime` |
| `downloads` | `downloadsAllTime` |
| `pulls` | `pullsAllTime` |
| `views` | `viewsAllTime` |
| `forks`, `likes`, `stars`, `subscribers` | none |

## When a resource is next collected

After a successful dispatch, the next collection is booked **from now**, not from the old due date.
After downtime a stale date would otherwise leave a resource due immediately, once per missed
interval.

A credential failure re-books the resource about an hour out instead of a full cadence, so a
repaired token resumes collection unattended and the alert repeats until it is fixed.

Changing a resource's cadence does not make it due. It sets the spacing applied after the next
successful collection.

#icicle-insights# #Reference# #Administrator# #Developer# #collection#
