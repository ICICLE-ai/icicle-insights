# Collection failures

The failure kinds a collection can end in, how loudly each is reported and where it shows up. For
administrators answering an alert and developers adding a collector.

## Failure kinds

Each failure carries a stable identifier. It appears in the log, in Slack and in the console's
**Recent failures** card.

| Identifier | Meaning | Severity | Re-booked in |
|---|---|---|---|
| `missing_token` | The account has no stored credential | Critical | 1 hour |
| `api_request_failed` with 401 or 403 | The platform rejected the token: expired, revoked or missing a scope | Critical | 1 hour |
| `api_request_failed` with another status | The platform answered with an error, such as 404 or 503 | Warning | 1 to 12 hours |
| `decoding_failed` | The platform's response no longer matches what the collector expects | Warning | 1 to 12 hours |
| `page_layout_changed` | A GHCR package page no longer has the markup the parser reads | Warning | 1 to 12 hours |

Failures reading the credential from Tapis Vault have their own identifiers:

| Identifier | Meaning | Severity | Re-booked in |
|---|---|---|---|
| `tapis_secret_not_found` | The vault entry is recorded, but Tapis Vault has no secret under that name | Critical | 1 hour |
| `tapis_request_failed` with 401 or 403 | Tapis refused `TAPIS_TOKEN`. It has usually expired | Critical | 1 hour |
| `tapis_request_failed` with another status | Tapis answered with an error | Warning | 1 to 12 hours |
| `tapis_invalid_response` | Tapis answered with something unreadable | Warning | 1 to 12 hours |
| `unknown` | Anything else | Warning | 1 to 12 hours |

A nightly database backup that fails has one identifier of its own:

| Identifier | Meaning | Severity | Tried again |
|---|---|---|---|
| `backup_failed` | The backup did not reach the bucket. The alert says which step failed and why | Warning | The next night, at 02:00 |

`pg_dump`'s own message goes to the worker's log, never to the alert, because it can quote
connection details.

**Critical** means someone has to act, usually by replacing a token. Everything else may clear on its
own.

## Suggested fixes in the alert

| Identifier | Suggested fix |
|---|---|
| `missing_token` | Add a vault entry for the account's platform token, then wait for the next sweep |
| `api_request_failed` 401 or 403 | Check the token has not expired and has the scopes the endpoint needs. Replace it; collection resumes on the next hourly sweep |
| `page_layout_changed` | Update the selectors in `GHCRPackagePage`, and replace the saved pages in `Tests/Fixtures/GHCR/` |

## Where failures appear

| Place | What it holds |
|---|---|
| Admin console, **Operations → Recent failures** | Failures that used up their retries, newest first |
| Process log of the `queues` worker | Every failure, with `job`, `subject` and `identifier` keys |
| Slack, `SLACK_WEBHOOK_URL` | Critical alerts, and warnings when no second webhook is set |
| Slack, `SLACK_WEBHOOK_URL_WARNINGS` | Warnings, when set |
| `job_failures` table | Every exhausted failure, for the console |

Without either webhook, alerts go to the log only.

## Alert format

| Severity | Slack title |
|---|---|
| Critical | 🔴 *CREDENTIAL* · `job` · account/resource |
| Warning | ⚠️ `job` · account/resource |

## Deduplication

One alert per identifier and severity is sent every 6 hours. A token that stops working fails every
resource under it, and Slack hears about it once. The log and the console still list each failure.

The data-loss alert for a GitHub gap past 14 days is not deduplicated. It fires once per outage per
resource and re-arms after the next success.

## Retry timing

| Stage | Delay |
|---|---|
| First retry | 30 seconds |
| Second retry | 2 minutes |
| Third retry | 8 minutes |
| After that | Re-booked as in the table above |

A resource whose account was deleted is skipped with a log warning, not retried. So is a queued job
whose resource no longer exists.

#icicle-insights# #Reference# #Administrator# #Developer#
