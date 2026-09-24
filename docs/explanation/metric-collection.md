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
[Watermarks](watermarks.md), which is the whole answer to that problem. How the resulting totals
gain a daily history is in [Metric history](metric-history.md).

Hugging Face is the easy case: the Hub publishes its own lifetime downloads figure, so Insights
assigns rather than accumulates and a repeated sweep is harmless. GHCR is the same case, because
GitHub's package page states its lifetime pulls.

## A sweep, end to end

1. The hourly clock finds resources whose due date has passed.
2. For each, it enqueues a typed job onto the `metrics` queue and books the next due date.
3. A worker claims the job and re-reads the resource from the database.
4. The worker resolves the account's credential through `SecretProvider`. GHCR and Patra need
   none, so their jobs skip this step.
5. The worker fetches **every** response it needs.
6. The worker writes snapshots and folds any rolling values, in one transaction.

Step 5 is deliberate. `SyncGitHubRepoStats` collects all three responses before creating a single
batch, so a failure partway through leaves no half-swept resource — gauges stranded without the
traffic rows that share their timestamp. There is a test for this.

Step 6 is the same guarantee against retries. A failure after the snapshot rows but before the
commit rolls them back, so the retry does not write a second set.

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

A resource whose **account** is deleted is skipped the same way, but logged at `warning`. The API
refuses to delete an account that still owns resources, so such an orphan predates that guard or
was made by hand. The sweep leaves its due date alone, so restoring the account resumes collection
on the next tick.

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

Alerts are deduplicated; the record is not. An expired `TAPIS_TOKEN` fails every resource at once,
and each re-books hourly, which used to mean about a hundred critical messages an hour. Now one
alert per identifier and severity goes out per six hours, claimed with an atomic `SET NX EX` in
Valkey so every worker shares it. Every failure is still logged and written to `job_failures`. If
Valkey cannot answer, the alert is sent anyway, because a lost alert is worse than a repeat. The
retention-window alert is exempt: it is already once per outage for each resource.

## Patra's card text

The Patra catalog sweep also keeps what each card says about its artifact. Every card gets a
description, author, category, and license; a model adds accuracy and keywords, a datasheet size
and format. The full list is in [Data model](../reference/data-model.md). The sweep rewrites them
for known cards as well as new ones, because Patra edits a card's text under the same identifier.
They only feed display, so a value of an unexpected type is stored as null rather than failing the
sweep.

## Provider quirks worth knowing

- **Hugging Face `expand[]` is an allowlist.** Asking for the lifetime downloads figure returns
  *only* the fields you name, so downloads and likes have to be listed too or they vanish.
- **GitHub's traffic array key differs by endpoint** — `clones` on one, `views` on the other, with
  an otherwise identical response shape.
- **The GitHub organisation endpoint is plural**: `/orgs/{org}`.
- **GHCR has no download API.** Its figures are read from the public package page, whose markup
  GitHub can change without notice. A change fails loudly as `page_layout_changed`. See
  [ADR 009](decisions/009-scraping-ghcr.md).
- **FluentKit has no row locking in this version.** The fold uses a PostgreSQL advisory transaction
  lock instead, which also covers the first sweep, where no watermark row exists yet.

#icicle-insights# #Explanation# #Developer# #collection#
