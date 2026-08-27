# Collection schedule

What Insights collects, when, and from where. For administrators and developers.

## The four clocks

Registered in `configure.swift` and evaluated by the single `queues --scheduled` process.

| Clock | Runs | Does | On demand |
|---|---|---|---|
| `CollectDueResources` | Hourly, on the hour | Enqueues a sync for every resource whose next collection has passed | `collect-resources` |
| `CollectAccountStats` | Monthly, 1st at 03:00 | Enqueues a follower sync for every GitHub account | `collect-accounts` |
| `CollectPatraCatalog` | Daily at 04:00 | Enqueues a catalog sync for every Patra account | `collect-patra-catalog` |
| `WarnExpiringServiceTokens` | Daily at 07:00 | Alerts on webhook tokens nearing expiry. Writes nothing | none |

Times use the scheduler process's own time zone. Set `TZ` explicitly if 03:00 must mean a
particular local hour.

Each on-demand command invokes the same job type as its clock, without changing or waiting for the
production schedule. See [Run collection immediately](../how-to/run-collection-immediately.md).

**The hourly clock is a scanner, not a collector.** It only picks up resources that are already
due. A resource with the default 7-day cadence is collected once a week, not hourly.

## Per platform

| Platform | Collected | Job | Cadence cap | Retention window |
|---|---|---|---|---|
| GitHub repository | Stars, forks, subscribers, clones, views | `SyncGitHubRepoStats` | 7 days | 14 days |
| GitHub account | Followers | `SyncGitHubOrgStats` | monthly, fixed | — |
| Hugging Face | Likes, 30-day downloads, lifetime downloads | `SyncHuggingFaceHubStats` | 30 days | none |
| GHCR | not collected | — | 30 days | none |
| npm | not collected | — | 30 days | none |
| PyPI | not collected | — | 30 days | none |
| Patra model | Deployment count, summed across the resource's cards | `SyncPatraDeployments` | 30 days | none |
| Patra dataset | nothing — Patra has no deployments endpoint for a dataset | `SyncPatraDeployments` | 30 days | none |

GHCR, npm, and PyPI resources can be registered, but the dispatcher logs and skips them. They are
still re-booked, so they will collect as soon as a job exists.

A Patra dataset is still collected on schedule even though it has no reading to write. The sweep
gets a definitive answer — there is nothing to count — and records that success like any other, so
the resource rotates normally instead of retrying forever for an endpoint that will never exist.

Patra's catalog — which resources exist at all — is discovered separately from this metric sweep.
`SyncPatraCatalog`, dispatched daily by `CollectPatraCatalog`, pages Patra's model and datasheet
lists and registers a resource and a card for each. `SyncPatraDeployments` then collects each
resource's deployment count on the normal hourly sweep, the same as any other platform.

Routing is on the **account's platform**, not the resource's kind. Kind says what a thing is, not
which API reports on it.

The cadence cap is **shorter** than the retention window, never equal to it: GitHub is capped at
half its window. A failed collection re-books on a capped backoff rather than costing a full
interval, so a miss costs at most twelve hours, never the whole cadence.
`ResourceController.create` and `update` enforce the cap.

A retention window of "none" means the platform cannot lose data this way — Hugging Face reports
its lifetime total outright, so a late sweep costs series density and nothing permanent. Only
GitHub's `clones` and `views` accumulate day by day and age out, and neither endpoint offers
backfill.

## How a metric is stored

| Shape | Examples | All-time handling |
|---|---|---|
| Gauge | stars, forks, subscribers, likes, followers, deployments | None. The series is the record |
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
| `deployments`, `forks`, `likes`, `stars`, `subscribers` | none |

## When a resource is next collected

After a successful dispatch, the next collection is booked **from now**, not from the old due date.
After downtime a stale date would otherwise leave a resource due immediately, once per missed
interval.

A credential failure re-books the resource about an hour out instead of a full cadence, so a
repaired token resumes collection unattended and the alert repeats until it is fixed.

Changing a resource's cadence does not make it due. It sets the spacing applied after the next
successful collection.

| State | Question it answers |
|---|---|
| `next_collection_at` | When may this be dispatched again |
| `last_collected_at` | When did a collection last succeed |
| `collection_interval_days` | Spacing booked after a success |

The dispatch-time advance is a lease, not the schedule. A successful sync re-books from the moment
it completed; an exhausted failure re-books on a capped backoff of 1 to 12 hours, scaled to how
overdue the resource is. See [ADR 008](../explanation/decisions/008-collection-backoff.md).

#icicle-insights# #Reference# #Administrator# #Developer# #collection#
