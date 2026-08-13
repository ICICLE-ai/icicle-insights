# ADR 005: Classified failures, retries, and alerting

**Status:** Accepted

Sync jobs retry with exponential backoff and classify their failures through `JobError`'s
`DebuggableError` conformance, which decides log severity, whether an alert is sent, and whether
the resource is re-booked ahead of its normal cadence.

Two failure kinds need opposite handling: a throttled or restarting platform wants another attempt
shortly, while an expired credential wants a person and will not fix itself. Retries alone cannot
express the second — `nextRetryIn(attempt:)` never sees the error — so the distinction is made
after the retry budget is spent, in `error(_:_:_:)`.

Re-booking is the part that matters operationally. `CollectDueResources` advances
`nextCollectionAt` when it dispatches rather than when the job succeeds, so without intervention a
credential failure removes a resource from collection for a full interval. Re-booking it hourly
keeps the failure visible and lets a repaired token resume collection unattended.

Credential failures arrive from two unrelated types — `JobError` when the platform rejects a token,
`TapisClientError` when the vault will not hand one over — and the second matters more, since every
account shares one vault. The classification is written in the queue's failure handler rather than
pushed onto `TapisClientError`, which stays the `AbortError` the HTTP boundary needs: what a vault
failure means to a job is the queue's concern. The tradeoff is an explicit list of cases in one
place instead of a conformance per error type.

Alerting goes through a provider-neutral `FailureNotifier`, mirroring `SecretProvider`, with Slack
as the first adapter and a no-op default so an unconfigured deployment still collects. `notify` is
deliberately non-throwing: `QueueWorker` clears a job only after `error(_:_:_:)` returns, so an
alert channel that threw would strand the job and stop the worker.

#icicle-insights# #architecture-decision# #queues# #observability# #alerting#
