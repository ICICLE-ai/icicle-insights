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

## Authentication and authorization

- Authenticators never reject. Each logs in its identity or returns quietly; only `Require`
  produces 401 or 403. Rejecting inside an authenticator would close public reads.
- Every mutating route carries a `Require`. Vault and service-token reads carry one too — their
  metadata enumerates which credentials exist and when they expire.
- `Require`'s predicate is synchronous and cannot query. Anything it needs — admin status — is
  resolved during authentication and carried on the identity.
- Verify a Tapis token's `tapis/tenant_id` against `TAPIS_TENANT`. A valid signature does not
  establish which tenant issued the token.
- Webhook signing keys live in their own `JWTKeyCollection`, never `app.jwt.keys`. JWTKit falls
  back to the default signer for an unknown `kid`, so sharing a collection would verify Tapis
  admins against the HMAC key and reject them.
- A webhook token's resource binding and expiry stay inside the signature, never in a claim the
  holder supplies or a parameter the request carries.
- Resolve the `jti` against a live row on every request, uncached. Caching delays revocation, which
  is the only thing the row exists for.
- `service_tokens` rows hold identifiers and metadata, never a credential.
- `ROOT_ADMIN_USERNAME` cannot be removed through the API, or an emptied table locks everyone out
  of the surface that manages it.
- An absent signing keyset is survivable; a *refused* read is not. Every command routes through
  `configure`, so failing hard on absence would take down `service-token init-key` itself — but a
  401 means the Tapis credentials are wrong and every collection job would fail silently.

## Data and HTTP

- Tests use the `test` database; development seed data is registered only in `.development`.
- Validate and normalize DTOs before creating Fluent models.
- Database TLS defaults secure; `DATABASE_TLS=disable` is for the local stock container only.
- Response-header middleware registers `at: .beginning`, ahead of `ErrorMiddleware`. Headers are
  applied on the way out, so anything registered later never sees an error response — and a 4xx
  without CORS headers is unreadable to the browser that caused it.
- Rate limiting fails open. A limiter that takes the API down with its counter store causes more
  harm than the abuse it prevents.

#icicle-insights# #invariants# #architecture# #correctness# #developer-documentation#
