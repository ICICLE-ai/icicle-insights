# Metric collection

How readings get into the database, and the two rules that keep them correct.

## The bug this fixed

GitHub's `/traffic/clones` and `/traffic/views` return a **rolling 14-day total** in their
top-level `count`, not a delta since the last sweep. The old code fed that straight into
`Metric.addToAllTime`, which does `total.reading += reading`. Every sweep re-added the days it
shared with the previous one, so `clonesAllTime` and `viewsAllTime` inflated without bound —
at a daily cadence, each day got counted about 14 times.

Hugging Face had the same shape of bug: its `downloads` is a trailing 30-day figure.

No inflation actually occurred, because nothing ever ran the jobs (see below). The July seed
figures are still valid.

## Two kinds of metric

| Kind | Examples | API reports | All-time handling |
|---|---|---|---|
| Gauge | stars, forks, subscribers, likes | full current value | none — `MetricType.allTime` is nil |
| Rolling window | clones, views (14d), downloads (30d) | overlapping window | watermark fold, or platform's own total |

A gauge needs no all-time row because **the series is the record** — one row per sweep, free to
fall as well as rise. That is what the Trend section on the dashboard plots.

## The watermark

`MetricWatermark` is one row per `(resource, metric type)` holding `countedThrough`: the newest
completed day already folded into the all-time total.

`Metric.foldDailyIntoAllTime` counts a day only if it is:

1. **newer than the watermark** — everything at or before it is already counted, and
2. **older than today's UTC midnight** — today is still accruing. Banking a partial day would
   record a low figure and then skip the rest of it, because the watermark would have moved
   past that day before the next sweep saw it complete.

The watermark is deliberately **not** the same thing as `Resource.nextCollectionAt`:

- `nextCollectionAt` — *when to fetch next*
- `countedThrough` — *what has been counted*

Keeping them separate is what lets a late sweep resume exactly where the last one stopped. Fuse
them and you are back to assuming sweeps land on schedule.

**Days that age out of the retention window before a sweep runs are gone.** Neither endpoint
offers backfill. `Platform.maxCollectionIntervalDays` (14 GitHub, 30 Hugging Face) is what
bounds the interval; `ResourceController.create` enforces it.

Hugging Face gets a snapshot instead of a fold — the Hub reports `downloadsAllTime` itself, so
`Metric.setAllTime` assigns rather than accumulates and re-running a sweep is harmless.

## Scheduling

- `Resource.nextCollectionAt` + `collectionIntervalDays` (default 7)
- `CollectDueResources` — hourly, dispatches everything with `nextCollectionAt <= now`, then
  advances each **from now**, not from the old due date. After downtime a stale date would
  otherwise leave a resource due immediately, once per missed interval.
- `CollectAccountStats` — daily, org followers. Per-Account, so it is kept out of the resource
  sweep, which would otherwise dispatch it once per resource the account owns.
- Routing is on `Account.platform`, not `Resource.type`: type says what a thing is, not which
  API reports on it. `ghcr` / `npm` / `pypi` are logged and skipped.

## Nothing ran before this

`app.queues.add(...)` only registers a handler. `serve` does **not** drain the queue. Before
this change nothing dispatched a job and no process consumed one, so every metric row came from
the `ICICLESnapshotJuly2026` seed.

Two processes are now required:

```
just queues      # queues --queue metrics    — runs the syncs
just scheduled   # queues --scheduled        — runs the sweeps
```

Run exactly one scheduler. Two would dispatch every due resource twice.

## Running the stack

Apple `container`, not Docker Compose. Needs macOS 26+ for user-defined networks.

```
just stack     # network, db, migrate, app, queues, scheduled
just stop      # stop all four containers
just clean     # stop, then delete the network
```

Containers share the `icicle-insights` network and resolve each other by name under `.test`,
so the app finds Postgres at `insights-db.test`.

`DATABASE_HOST` is intentionally absent from `.env` — `configure.swift` falls back to localhost
for local `swift run` / `just test`, and the container recipes inject the network name. Copy
`.env.example` to `.env` first; the `TAPIS_*` values are required or every process aborts at
boot.

## Gotchas

- **`expand[]` is a whitelist.** `downloadsAllTime` is absent from the Hub's default response,
  and asking for it returns *only* the fields you name. `downloads` and `likes` have to be
  listed too or they vanish:
  `?expand[]=downloads&expand[]=downloadsAllTime&expand[]=likes`
- **The traffic array key differs by endpoint** — `clones` on one, `views` on the other.
- **The org endpoint is plural.** `/orgs/{org}`; the old `/org/{org}` 404'd, so
  `SyncGitHubOrgStats` had never returned data.
- **FluentKit has no row locking** in this version. `foldDailyIntoAllTime` uses a
  transaction-scoped `pg_advisory_xact_lock(hashtext(...))` instead, which also covers the
  first sweep where no watermark row exists yet. `hashtext` rather than Swift's `hashValue`,
  which is seeded per process.
- **`/metrics` now defaults to a 1000-row limit.** Rows are newest-first, so the trend chart
  shows a trailing window — roughly 10 weeks at ~103 rows per weekly sweep. Per-type fetches
  or downsampling is the follow-up when that gets tight.
- **Fetch-on-create is dormant.** `resources.post(use: create)` is still commented out pending
  auth middleware. The dispatch is in the handler and correct; it fires when that is uncommented.

## Verification status

Built clean, `swift-format` clean, and the 4 decoder tests in `TrafficDecodingTests` pass.

The 7 tests in `MetricAllTimeTests` — double-count safety, partial-day exclusion, watermark
blocking a wider window, retention-gap loss — **have not been run.** They need a live `test`
database. Run them with:

```
just db
just test
```
