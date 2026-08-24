# Metric collection

How platform readings become trustworthy history. For developers.

## Two kinds of number

Platforms report two shapes, and they need opposite handling.

| Kind | Examples | The platform reports | All-time handling |
|---|---|---|---|
| Gauge | stars, forks, subscribers, likes, followers | the current value | none |
| Rolling window | clones, views, 30-day downloads | an overlapping recent window | folded, or replaced |

A gauge needs no all-time row because **the series is the record**. One row per sweep, free to fall
as well as rise. That is what the dashboard's trend chart plots.

A rolling window cannot simply be added, because consecutive responses overlap. See
[Watermarks](watermarks.md), which is the whole answer to that problem.

Hugging Face is the easy case: the Hub publishes its own lifetime downloads figure, so Insights
assigns rather than accumulates and a repeated sweep is harmless.

## A sweep, end to end

1. The hourly clock finds resources whose due date has passed.
2. For each, it enqueues a typed job onto the `metrics` queue and books the next due date.
3. A worker claims the job and re-reads the resource from the database.
4. The worker resolves the account's credential through `SecretProvider`.
5. The worker fetches **every** response it needs.
6. The worker writes snapshots and folds any rolling values.

Step 5 is deliberate. `SyncGitHubRepoStats` collects all three responses before creating a single
batch, so a failure partway through leaves no half-swept resource — gauges stranded without the
traffic rows that share their timestamp. There is a test for this.

The due date is booked at **dispatch**, not on success. That keeps the sweep cheap and stateless,
and is why a credential failure re-books the resource an hour out rather than letting it sit out a
full cadence.

## Routing

Collection routes on the **account's platform**, not the resource's kind. A kind says what a thing
is; it does not say which API reports on it. A container image and a repository can both live under
a GitHub account.

Routing lives in one extension rather than at each call site, so wiring a new platform lights up
both the hourly sweep and creation-time collection at once.

Unhandled platforms are logged and skipped, then re-booked normally. Adding the job later is all
that is needed.

## When the subject is gone

A job whose resource or account no longer exists logs at `notice` and returns, rather than
throwing.

The worker decides whether to retry from the remaining attempt count alone. There is no per-error
hook, and the retry budget is fixed at dispatch, so throwing would spend four attempts across
roughly ten minutes rediscovering that a row is gone. A deleted subject is not a failure to recover
from; it is work that no longer needs doing.

## Failure handling

Failures divide into two kinds that want opposite treatment.

| Kind | Example | Severity | Effect |
|---|---|---|---|
| Platform | rate limit, 5xx, timeout | warning | Retried with backoff, then left to the normal cadence |
| Credential | expired token, vault refusal | critical | Alerted, and the resource re-booked about an hour out |

A throttled platform wants another attempt shortly. An expired credential wants a person, and will
not fix itself. Retries alone cannot express the second, so the distinction is made after the retry
budget is spent.

GitHub uses 403 for both an expired token and a secondary rate limit, and the response body is the
only way to tell them apart. That is why the error carries the body and the alert quotes it.

Alert delivery is never load-bearing. The notifier cannot throw: the worker clears a job only after
the failure handler returns, so a failing alert channel would strand the job and stop the worker.

## Provider quirks worth knowing

- **Hugging Face `expand[]` is an allowlist.** Asking for the lifetime downloads figure returns
  *only* the fields you name, so downloads and likes have to be listed too or they vanish.
- **GitHub's traffic array key differs by endpoint** — `clones` on one, `views` on the other, with
  an otherwise identical response shape.
- **The GitHub organisation endpoint is plural**: `/orgs/{org}`.
- **FluentKit has no row locking in this version.** The fold uses a PostgreSQL advisory transaction
  lock instead, which also covers the first sweep, where no watermark row exists yet.

#icicle-insights# #Explanation# #Developer# #collection#
