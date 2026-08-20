# Troubleshooting

## Jobs dispatch but metrics never appear

Check `container list` and `container logs insights-queues`. The HTTP server and scheduler do
not execute `metrics` jobs. Restart the drainer with `just queues`.

## `collect-now` dispatches zero jobs

Only due rows qualify. Inspect `next_collection_at` or use `just collect-all-now` locally. See
[testing-collection.md](testing-collection.md) before forcing production scheduling state.

## A provider token cannot be resolved

Confirm `SECRET_PROVIDER`, provider configuration, the account's secret-reference name, and that
the same name exists in the selected backend. Switching providers does not migrate values.

From a sync job this is a **credential** failure like any other: `tapis_secret_not_found` or
`tapis_request_failed` at `.critical`, a 🔴 alert, and the resource re-booked hourly. An expired
`TAPIS_TOKEN` breaks collection for every account at once while the platform APIs are healthy, so
expect the alert to arrive from whichever resource happened to be swept first.

## All-time totals do not increase

This is often correct: no completed day newer than `countedThrough` was returned. Inspect
`metric_watermarks` and read [watermarks.md](watermarks.md).

## GitHub responds with 403

Inspect rate-limit headers and token permissions. More workers consume the same allowance faster;
reduce concurrency or add provider-aware throttling rather than scaling up.

Note that a 403 is classified as a **credential** failure, so it alerts at `.critical` and re-books
the resource hourly. GitHub uses the same status for a secondary rate limit as for an expired
token, and the body is the only way to tell them apart — which is why `apiRequestFailed` carries
the response body and the alert quotes it.

## The same credential alert fires every hour

Working as intended. A credential failure re-books the resource about an hour out instead of
letting it sit out a full `collectionIntervalDays`, so the alert repeats until the token is
repaired. Rotate the secret in the provider; the next sweep picks it up with no backfill needed.

To stop the alerts without fixing the token, clear the resource's `next_collection_at`, which the
sweep's `<= now` filter skips.

## Failures are logged but never reach Slack

Check `SLACK_WEBHOOK_URL`. Unset or empty selects `NoopNotifier`, which is the intended default
for tests and local runs — `configure` logs `SLACK_WEBHOOK_URL is unset` once at boot when that
happens. If it is set, look for `Slack rejected the failure alert` (a revoked webhook answers
403/404) or `Could not deliver the failure alert to Slack`. Alert delivery never fails a job, so
its only trace is that log line.

Container recipes pass `--env-file .env --env-file .env.container`, in that order, so the webhook
belongs in `.env` — which is gitignored. Anything secret in `.env.container` is secret in the
repository.

## Repeated `/v1/models` requests

Those are external client polls reaching the HTTP service, not queue activity. Use request IDs
and client process inspection to locate the caller.

## Apple Container build cannot resolve packages

The builder uses explicit DNS and 8 GiB memory. Override `CONTAINER_BUILD_DNS_PRIMARY` and
`CONTAINER_BUILD_DNS_SECONDARY`, or recreate the builder with suitable resolvers.

## Vapor logs missing `.env.development` or `.env.production`

At debug level Vapor reports optional dotenv lookup failures. Container configuration comes from
the supplied `.env` and `.env.container`; use `LOG_LEVEL=info` to suppress optional lookup noise.

#icicle-insights# #troubleshooting# #operations# #containers# #developer-documentation#
