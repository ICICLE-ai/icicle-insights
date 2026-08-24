# Secret providers

Why credentials sit behind an interface. For developers.

Collection jobs need platform tokens. Those tokens must not live in PostgreSQL, must not reach
logs, and must be replaceable without touching every job that uses one.

`SecretProvider` is the seam that makes all three true at once.

```swift
protocol SecretProvider: Sendable {
  func readSecret(named name: String) async throws -> Secret
  func writeSecret(named name: String, secret: String) async throws
  func destroySecret(named name: String) async throws
}
```

Three operations, named credentials, nothing platform-specific. Adapters own backend
authentication, payload shapes, and error translation.

## What the database holds

A reference, never a value. A `vaults` row records the *name* of a secret and some metadata:
which account uses it, when it expires, when it was last rotated. The value lives in the backend.

That is why the console's Vaults screen can list credentials without ever being able to show one.

## Redaction

`Secret` redacts its string conversion, debug output, and reflection. Interpolating one into a log
line produces a placeholder, not the token.

Reading the real value is a deliberate, explicit call, and should happen only while building an
authenticated outbound request. Making it awkward is the point: the easy path is the safe one.

## Why it is a protocol and not a Tapis client

Because it had a real second implementation. Tests replace the provider with an in-memory
dictionary, which is how key rotation, the absent-keyset cases, and every job test run without
touching a live vault.

That is the bar for a seam in this codebase. `SecretProvider` and `FailureNotifier` both cleared
it. Nothing else was abstracted on the theory that it might be useful later.

The composition root picks the adapter once, and an unsupported value fails at boot rather than
later inside a job.

## Adding one

The mechanics are in [Add a secret provider](../how-to/add-a-secret-provider.md). Two design
points are worth stating here.

**Read-only backends do not fit cleanly.** Environment variables and mounted Kubernetes Secrets can
be read but not written. Model that explicitly with a documented unsupported-operation error, or
split the contract into a reader and a writer, rather than silently doing nothing on a write.

**Switching providers does not migrate values.** Changing the setting changes where lookups go.
Provision the same names in the destination first, verify reads, then switch, and keep the previous
backend available through the rollback window.

## Failure alerting mirrors this

`FailureNotifier` has the same shape and the same reasoning: a Slack adapter, a no-op default, and
a composition root that picks one. An unconfigured deployment still collects; failures stay in the
log.

Its one unusual constraint is that `notify` cannot throw. The worker clears a job only after the
failure handler returns, so an alert channel that threw would strand the job and stop the worker.
Alerting is never allowed to be load-bearing.

#icicle-insights# #Explanation# #Developer# #credentials#
