# Test reference

What the suite covers, how the harness works, and which tests need credentials.

**158 tests across 13 suites.** Everything lives in `Tests/InsightsTests/`.

```bash
just test          # swift test --no-parallel
```

## Before it will run at all

Two settings are not optional, and getting either wrong fails the *entire* suite rather than one
test — which reads like the code is broken when it is not:

- **`.env` must exist.** `TapisConfig.fromEnvironment()` throws on a missing `TAPIS_BASE_URL`, and
  it runs inside `configure`, so every test that boots an app dies in setup. Copy `.env.example`.
- **`DATABASE_TLS=disable`** against the local Postgres container, which serves no TLS. Without it
  every connection fails with `PSQLError(code: sslUnsupported)`.

Dummy Tapis values are fine for all but three tests — see [Live credentials](#live-credentials).

## Why the suite is serial

Every suite is `.serialized`, and `just test` passes `--no-parallel` on top. Suites share the one
`test` database and each runs its own migrate/revert around itself, so any overlap has one suite
reverting the schema out from under another.

Several `HardeningTests` cases additionally set process environment variables (`CORS_ORIGINS`,
`FRAME_ANCESTORS`) that `configure` reads at boot. Process environment is global; running those
concurrently would make them read each other's settings.

## The harness

### `withInsightsApp(setUp:_:)`

Boots a `.testing` application through the real `configure`, installs test credentials, migrates,
runs the test, then reverts and shuts down.

**The name is load-bearing.** `VaporTesting` exports a generic `withApp` that boots a bare
application *without* `configure` — no routes, no database. For a single-expression closure the
type checker prefers that overload, silently handing the test an empty app, which surfaces as an
inexplicable 404. Adding a second statement changes which overload wins, so the trap is invisible
until it bites. The distinct name removes it. Do not rename this back.

`setUp` runs between `configure` and the migration, which is where a test swaps the queues driver:
the provider initialises the storage later dispatches read from, so it must be in place before
anything enqueues.

### `withQueueApp(_:)`

`withInsightsApp` with the in-memory queues driver, so dispatches are inspectable through
`app.queues.asyncTest` and never touch the jobs table.

### `queueContext(for:)`

The context a worker hands a scheduled job, built by hand so a sweep can be driven directly rather
than through a live scheduler.

## What `.testing` skips

`configure` deliberately does not reach the network under `.testing`: it skips both the Tapis
tenant key fetch and the Vault read for the signing keyset. `installTestCredentials` supplies both
in memory instead.

**This is worth knowing because it hides things.** Two real bugs were invisible to the suite for
exactly this reason:

- The tenant PEM arrives from Tapis as one unwrapped line, which SwiftASN1 rejects. Every
  production boot would have crashed. There is now a regression test feeding an unwrapped PEM
  through the same path (`An unwrapped tenant PEM still parses`).
- The signing keyset read threw on absence, which made `service-token init-key` unrunnable on a
  fresh deployment. Now covered by four tests in `HardeningTests`, but only after a live run
  surfaced it.

Anything that only executes outside `.testing` needs either a direct unit test of the function or
a manual check against staging.

## Fixtures and stubs

| Helper | Purpose |
|---|---|
| `TestKeys` | Two throwaway RSA keypairs, checked in, used nowhere else. Tokens are signed locally; no test touches a live tenant. The second exists only to prove a well-formed token from the wrong issuer is rejected. |
| `installTestCredentials` | Registers the Tapis test key and a webhook signing keyset, then mints `app.adminToken` and `app.userToken`. |
| `signTapisToken` | Signs a Tapis-shaped token. A key other than the tenant's gets its own collection — adding it to `app.jwt.keys` would make it *trusted*, the opposite of what those tests assert. |
| `issueWebhookToken` | Mints through `ServiceTokenIssuer`, the same path the CLI and controller use, so fixtures cannot drift from production behaviour. |
| `signWebhookToken` | Signs directly, bypassing the issuer, for tokens no legitimate path would produce: expired, foreign-issuer, wrong key, orphaned `jti`. |
| `InMemorySecrets` | A dictionary-backed `SecretProvider`, for key rotation and the absent-keyset cases. |
| `StubClient` | Answers everything with a fixed status, to drive `TapisClientError` paths. |
| `StubHTTPClient` / `stubAPI` | Answers platform calls from canned routes and records requests, so a test can assert on the URL a job built. Matches paths exactly, because `/repos/o/n` is a prefix of `/repos/o/n/traffic/clones`. |
| `RecordingNotifier` | Captures alerts instead of sending them. |
| `FlakyQueuesDriver` | A driver whose first `set` throws, so the per-resource dispatch-failure branch can be reached at all. |

## Suites

### Authentication — 22 tests

The two credential paths and, most importantly, where they cross.

Tapis path: anonymous reads open, vault reads refused; admin accepted; authenticated non-admin
403; expired, wrong-keypair, foreign-tenant, and non-JWT bearers all 401.

Webhook path: a token posting to its own resource and to another; revoked, expired, wrong key,
foreign issuer, unknown `jti`, empty bearer.

The crossover cases are the ones most likely to break and least likely to be written: an admin on
the webhook route for any resource, a webhook token on an admin route (403, not 401), a webhook
token trying to mint another, a Tapis token arriving where a webhook token is expected.

Two tests look redundant and are not. The foreign-tenant case and the bad-signature case fail for
different reasons, and the former is what regresses if someone decides the tenant comparison is
unnecessary. The unknown-`jti` case proves revocation is enforced by row presence rather than by a
flag someone could forget to check.

### Hardening — 35 tests

Response headers on success *and* on errors — the placement regression worth guarding, since
headers are stamped on the way out and a middleware registered after `ErrorMiddleware` never sees
an error response. CORS allowlist behaviour. Per-token rate limits, including that an unreachable
counter store still serves traffic.

Frame ancestors: denied by default, an allowlist permitting an origin and dropping
`X-Frame-Options`, a malformed entry discarded rather than widening the policy.

Request IDs: minted, echoed, and — the security-relevant ones — a newline-carrying or over-long
inbound value replaced rather than echoed, since that header reaches log metadata verbatim.

Signing keys: rotation keeping issued tokens working, retirement bounded, the unwrapped PEM
regression, and the four absent-keyset cases (survivable, a refused read still fatal, minting
explains itself, webhook tokens authenticate nobody).

Admins: root admin with an empty table, granted access, revocation on the next request, and that
the root admin cannot be removed through the API.

Health probes.

### Service Token Controller — 9 tests

Minting over HTTP returns the token exactly once and it works; revoking stops it; revoked rows are
retained as the audit trail. Non-admins, webhook tokens, and anonymous callers are all refused —
a leaked token must not become a credential-minting oracle.

### Vault Controller — 16 tests

Name normalisation, validation (blank name and token, expiry range and past dates, duplicate name
per account), upstream status mapping (5xx → 502, 4xx → 500), and that a failed secret write rolls
back the vault row rather than leaving a row pointing at a secret that does not exist.

### Job failure handling — 13 tests

Which failures are credential failures and therefore critical, versus platform failures that alert
at warning. Retry and backoff behaviour, re-booking on credential failure, leaving the normal
cadence alone otherwise, and that an unreachable alert channel does not fail the job.

### Queue sweeps — 7 tests

Only due resources dispatch; a dispatched resource is re-booked from now rather than its old due
date; each platform routes to its own job; a platform with no job is skipped but still re-booked;
one dispatch failure leaves that resource due without stranding the rest of the sweep.

### Metric all-time folding — 7 tests

The double-count prevention. Re-folding the same window counts each day once; today is excluded
while partial and counted once complete; a window reaching past the watermark folds only its new
tail; a gap longer than retention folds only what remains; gauges keep no all-time row.

### Sync jobs — 10 tests

End-to-end sweeps per platform against stubbed APIs, the error paths (missing resource, missing
vault, failed fetch writing *no* metrics at all, malformed body), and URL construction.

### GitHub traffic decoding — 4 tests

The one non-serialized suite — pure decoding, no database. `clones` and `views` share a response
shape differing only in the array's name.

### Account / Resource / Release / Metric Controllers — 35 tests

CRUD, validation, filtering, and the admin guard on each mutating route.

## Live credentials

Three `VaultControllerTests` reach real Tapis, because the adapter needs real credentials even to
fail usefully:

- `Create lowercases the name`
- `Update sets the expiration date`
- `Delete vault`

They **write and destroy real secrets**, so point `.env` at the staging tenant
(`https://icicleai.staging.tapis.io/v3`, tenant `icicleai`) rather than production. With dummy
credentials they fail with 500s and everything else still passes.

Tapis tokens are short-lived. A batch of otherwise-inexplicable vault failures usually means the
token expired.

## Deliberately not covered

- **Anything requiring a live Tapis boot** — the tenant key fetch and the vault keyset read are
  skipped under `.testing`. Verified manually against staging instead.
- **A real rotation across a restart.** The suite proves rotation is additive in memory; only a
  restart proves the retired key was persisted. Exercised by hand — see `TODO.md` §7.
- **The scheduler's clocks.** Jobs are driven directly through `queueContext`; that `.hourly()` and
  `.monthly()` are wired correctly is not asserted.
- **CI.** `.github/workflows/build.yaml` builds the image and never runs `swift test`.

#icicle-insights# #testing# #developer-documentation#
