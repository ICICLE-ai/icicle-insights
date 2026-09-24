# ADR 009: GHCR is scraped, on the metrics queue

**Status:** Accepted

Why container downloads come from a web page, why that job shares the `metrics` queue, and how a
broken scrape shows itself. For developers.

## Context

GHCR containers could be registered, but nothing collected them. The dispatcher logged and skipped
them. Their only figures were `pullsAllTime` values copied by hand into the July development seed.

GitHub's Packages API describes a container and its versions. It reports no download count. The
package page does: a "Total downloads" figure, and a chart of the last 30 days with one bar per day.
That page is public, and GitHub serves the same figures to an anonymous visitor.

A page is not an interface. GitHub can change its markup at any time, without notice or a version.
Whatever reads it has to assume that will happen, and make it loud when it does.

## Decision

`SyncGHCRStats` fetches the package page anonymously and hands the HTML to `GHCRPackagePage`, a pure
parser. It reads two things:

- the lifetime total, from the `title` of the `<h3>` after "Total downloads";
- each day's count and date, from the data attributes of the chart's bars.

The total is stored with `Metric.setAllTime` as `pullsAllTime`, because GitHub reports it
outright. The 30 days are summed into `pulls`, a trailing window, the same shape as the Hub's
`downloads`. Nothing is folded through a watermark.

The job sends no credential, for Patra's reason. A token adds nothing to a public page, and could
only widen what reaches a public dashboard.

It runs on the existing `metrics` queue, with the same retries and failure handling as every
other collector.

## Why the metrics queue

The alternative was a queue of its own, on the grounds that scraping fails differently and more
slowly than an API call. Neither difference holds up at this volume.

A new queue is a new worker process in every deployment. It needs a Compose service, a container
recipe, and a pod. If one deployment forgets it, GHCR jobs wait in Valkey forever and nothing
reports it. That is a standing cost for roughly six page fetches a day: the July snapshot's
forty-one containers, on the default seven-day cadence.

Latency is bounded the same way as any API call. The shared HTTP client's 30-second read timeout
applies to a page as much as to JSON, so a slow page holds a worker slot no longer than a slow API.

A redesign fails every GHCR resource at once, but each fails fast, before any write. It cannot
block other platforms' jobs, and it alerts once however many resources it breaks.

## What breaks it, and how you would know

| Change at GitHub | What happens |
|---|---|
| The page's markup is redesigned | `page_layout_changed`, naming `GHCRPackagePage` in its help |
| The total is shown only abbreviated, such as `1.2K` | `page_layout_changed`, rather than a rounded total |
| The chart holds more than 30 bars | `page_layout_changed`, rather than a longer window stored as 30 days |
| The package is deleted or made private | `api_request_failed` with status 404, after both owner addresses |
| github.com throttles or blocks the client | `api_request_failed` with GitHub's status |

One gap remains. Classification reads only the status code, so a 401 or 403 from github.com would be
reported as a credential failure, although no credential is sent. Patra's anonymous collectors share
it. No such response has been seen from a package page.

`page_layout_changed` is not a credential failure. It logs at `error`, alerts at warning, and is
recorded in `job_failures` for every resource. Its Slack alert is deduplicated like every other: one
per identifier and severity every six hours, however many resources fail.

The resources re-book on the capped backoff of one to twelve hours, so collection resumes by
itself once the parser is fixed and deployed. The three retries before that are spent on a failure
no retry can fix, as with an undecodable JSON body. The queue cannot tell the two apart.

Nothing is lost while it is broken. GHCR has no retention window: the next successful sweep reads
GitHub's lifetime total again. Only the 30-day series has a gap.

## Consequences

The parser is the only code that knows the page's shape. A fix means updating its selectors and
replacing the saved pages in `Tests/Fixtures/GHCR/`, which its tests parse.

A container linked to a repository answers its organization address with a redirect to the
repository's package page. The HTTP client follows it; the job never sees it.

The newest bar is today, still accruing, so each `pulls` reading includes a partial day.

#icicle-insights# #Explanation# #Developer# #decisions# #collection#
