# Test suite

What the suite covers. For developers.

**329 tests across 23 suites**, all in `Tests/InsightsTests/`. Parameterised tests count once.

```bash
just test
```

To run them at all, see [Run the tests](../how-to/run-the-tests.md). Two settings are mandatory
and their absence fails every test, not one.

## Suites

| Suite | Tests | Covers |
|---|---|---|
| `SyncJobTests` | 53 | Each platform's sweep against stubbed APIs, every error branch, orphans, retry safety, and Patra card text |
| `HardeningTests` | 49 | Headers, CORS, rate limits and client addresses, request IDs, key rotation, admins, pool sizes, absent keyset |
| `JobFailureTests` | 31 | Failure classification, retries, backoff, re-booking, alert deduplication |
| `MetricControllerTests` | 24 | Metric CRUD, filters, validation, admin guard |
| `AuthenticationTests` | 22 | Both credential paths and where they cross |
| `ResourceControllerTests` | 21 | Resource CRUD, cadence caps, admin guard, first dispatch, deleted links |
| `VaultControllerTests` | 15 | Name normalisation, validation, upstream status mapping, rollback |
| `MetricAllTimeTests` | 13 | Double-count prevention, the watermark fold, its locks, daily snapshots |
| `PatraCardDescriptionTests` | 13 | Reading Patra's card text: fallback order, lenient types, trimming |
| `AccountControllerTests` | 12 | Account CRUD, validation, and the delete guard |
| `InsightsControllerTests` | 12 | The three summary routes: carry-forward, filters, no row cap, lifetime history, parameters |
| `ReleaseControllerTests` | 10 | Release CRUD and validation |
| `ServiceTokenControllerTests` | 10 | Minting over HTTP, revocation, refusals |
| `QueueSweepTests` | 9 | Which job a platform dispatches, how due dates advance, orphans |
| `TapisTokenExpiryTests` | 9 | Reading `TAPIS_TOKEN`'s expiry and the daily warning |
| `ServiceTokenExpiryTests` | 8 | The daily expiry warning and its thresholds |
| `PatraAPITests` | 4 | Paging and error handling against a stubbed Patra |
| `AdminInsightControllerTests` | 4 | The admin-only operational projections |
| `TrafficDecodingTests` | 4 | The `clones`/`views` array-key split |
| `PatraAPITimestampsTests` | 2 | Patra's timestamp format, against captured responses |
| `StubPagedAPITests` | 2 | The query-aware stub itself, in `TestSupport.swift` |
| `MigrationLockTests` | 1 | `migrate-locked` takes its advisory lock |
| `PatraCardTests` | 1 | `card_uuid` uniqueness |

## Why it is serial

Every database suite with more than one test is `.serialized`, and `just test` adds
`--no-parallel` on top.

Suites share the one `test` database and each migrates and reverts around itself. Any overlap has
one suite reverting the schema out from under another.

Several `HardeningTests` cases also set process environment variables that `configure` reads at
boot. Process environment is global; running those concurrently would make them read each other's
settings.

`TrafficDecodingTests`, `PatraAPITimestampsTests`, and `PatraCardDescriptionTests` need no
database. They are pure decoding.

## Harness

| Helper | Provides |
|---|---|
| `withInsightsApp(setUp:_:)` | A `.testing` app booted through the real `configure`, migrated, then reverted |
| `withQueueApp(_:)` | The same with the in-memory queues driver, so dispatches are inspectable |
| `queueContext(for:)` | The context a worker hands a scheduled job, so a sweep can be driven directly |

`setUp` runs between `configure` and the migration. That is where a test swaps the queues driver:
the provider initialises the storage later dispatches read from, so it must be in place before
anything enqueues.

**Do not rename `withInsightsApp`.** See [Invariants](invariants.md).

## Fixtures

| Helper | Purpose |
|---|---|
| `TestKeys` | Two throwaway RSA keypairs. The second exists to prove a well-formed token from the wrong issuer is rejected |
| `installTestCredentials` | Registers the test tenant key and a webhook keyset, then mints admin and non-admin tokens |
| `signTapisToken` | Signs a Tapis-shaped token |
| `issueWebhookToken` | Mints through `ServiceTokenIssuer`, the same path production uses |
| `signWebhookToken` | Signs directly, for tokens no legitimate path would produce |
| `InMemorySecrets` | A dictionary-backed `SecretProvider` |
| `StubClient` | Answers everything with a fixed status |
| `StubHTTPClient` / `stubAPI` | Answers platform calls from canned routes and records requests |
| `RecordingNotifier` | Captures alerts instead of sending them |
| `FlakyQueuesDriver` | First `set` throws, so the dispatch-failure branch is reachable |

`stubAPI` matches paths exactly, because `/repos/o/n` is a prefix of `/repos/o/n/traffic/clones`.

## What `.testing` skips

`configure` does not reach the network under `.testing`. It skips both the Tapis tenant key fetch
and the vault read for the signing keyset; `installTestCredentials` supplies both in memory.

**This hides things.** Two real bugs were invisible to the suite for exactly this reason:

- The tenant PEM arrives from Tapis as one unwrapped line, which SwiftASN1 rejects. Every
  production boot would have crashed.
- The signing keyset read threw on absence, making `service-token init-key` unrunnable on a fresh
  deployment.

Both now have regression tests, but only after a live run surfaced them. Anything that executes
only outside `.testing` needs a direct unit test or a manual check against staging.

## Tests needing live credentials

Three `VaultControllerTests` reach real Tapis, because the adapter needs real credentials even to
fail usefully. They **write and destroy real secrets**, so point `.env` at staging.

They carry `.enabled(if: hasLiveTapisCredentials)` and skip rather than fail when no usable token
is configured. The check reads `exp` from the token rather than just its shape: Tapis tokens last
hours, so "looks like a JWT" and "will authenticate" are different questions.

## Deliberately not covered

- Anything needing a live Tapis boot. Verified against staging by hand.
- A real key rotation across a restart. The suite proves rotation is additive in memory; only a
  restart proves the retired key was persisted.
- The scheduler's clocks. Jobs are driven directly through `queueContext`; that `.hourly()` and
  `.monthly()` are wired correctly is not asserted.

#icicle-insights# #Reference# #Developer# #testing#
