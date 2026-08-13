# System invariants

These are correctness rules, not preferences. A change that violates one needs an explicit new
design and tests.

## Queues and scheduling

- Run exactly one scheduler replica. Two schedulers can enqueue the same scheduled work twice.
- Named queue workers may scale horizontally; each available payload is claimed atomically.
- Queue execution is at-least-once, not exactly-once. Jobs must tolerate retries.
- Every named queue has a running worker; `serve` handles HTTP traffic independently.
- Scheduled jobs dispatch work to workers, keeping remote synchronization off the scheduler.
- Sync jobs are dispatched with a retry budget and back off between attempts; an immediate requeue
  is never a retry strategy against a remote API.
- Alert delivery is never load-bearing. `FailureNotifier.notify` cannot throw: the worker clears a
  job only after `error(_:_:_:)` returns, so a failing alert channel would strand the job.
- A credential failure re-books its resource inside the sweep interval, so a repaired token
  resumes collection without an operator forcing a backfill.

## Metrics

- Fetch all required provider responses before writing a sweep; avoid partial snapshots.
- Fold rolling-window daily values through their watermark before updating an all-time value.
- Fold only completed UTC days newer than the metric watermark.
- Advance watermarks only through completed UTC days.
- Lock a `(resource, metric type)` fold before read-modify-write updates.
- Collection intervals must not exceed provider retention windows; expired days cannot be
  reconstructed by a watermark.

## Credentials

- Jobs and controllers access credentials through `SecretProvider`.
- `configure.swift` selects the concrete provider during application composition.
- PostgreSQL stores secret references; plaintext token values remain in the selected provider.
- Logs and errors preserve the redaction provided by `Secret`.
- Provider changes include provisioning matching secret names in the destination backend.

## Data and HTTP

- Tests use the `test` database; development seed data is registered only in `.development`.
- Validate and normalize DTOs before creating Fluent models.
- Keep mutation routes protected or disabled until authorization is in place.
- Database TLS defaults secure; `DATABASE_TLS=disable` is for the local stock container only.

#icicle-insights# #invariants# #architecture# #correctness# #developer-documentation#
