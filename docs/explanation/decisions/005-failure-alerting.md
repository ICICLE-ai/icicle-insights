# ADR 005: Failures are classified, then alerted

**Status:** Accepted

## Context

Two failure kinds need opposite handling. A throttled or restarting platform wants another attempt
shortly. An expired credential wants a person, and will not fix itself.

Retries alone cannot express the second: the backoff calculation never sees the error.

A further complication is that credential failures arrive from two unrelated types — one when the
platform rejects a token, another when the vault will not hand one over — and the second matters
more, because every account shares one vault.

## Decision

Sync jobs retry with exponential backoff. Once the retry budget is spent, the failure handler
classifies the error, which decides log severity, whether an alert is sent, and whether the resource
is re-booked ahead of its normal cadence.

The classification lives in the queue's failure handler rather than on the error types.

Alerts go through a provider-neutral `FailureNotifier`, with Slack as the first adapter and a no-op
default.

## Consequences

Re-booking is the part that matters operationally. The due date advances at dispatch, not on
success, so without intervention a credential failure would remove a resource from collection for a
full interval. Re-booking it about an hour out keeps the failure visible and lets a repaired token
resume collection unattended. Credential failures were re-booked hourly from the start; every other
failure was not, which [ADR 008](008-collection-backoff.md) corrects.

The same alert therefore repeats hourly until the credential is fixed. That is intended, not a bug.

Keeping classification in the queue means an explicit list of cases in one place, rather than a
conformance per error type. The vault error stays the type the HTTP boundary needs; what a vault
failure *means to a job* is the queue's concern.

`notify` cannot throw. The worker clears a job only after the failure handler returns, so an alert
channel that threw would strand the job and stop the worker. Alerting is never load-bearing.

With no webhook configured the notifier is a no-op and failures stay in the log, which is what
every test run and local invocation wants. Failures are also persisted, so the console can show them
regardless.

#icicle-insights# #Explanation# #Developer# #decisions# #alerting#
