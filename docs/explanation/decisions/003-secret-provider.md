# ADR 003: Credentials behind a provider interface

**Status:** Accepted

## Context

Collection jobs need platform tokens. Storing them in PostgreSQL would turn a database leak into a
credential leak, and calling a vault client directly from every job would make the backend
impossible to change.

## Decision

Jobs and controllers depend on `SecretProvider`: read, write, and destroy a named secret. The
composition root selects one concrete adapter. Tapis Vault is the current one.

PostgreSQL stores the *name* of a secret and its metadata. The value stays in the backend.

## Consequences

Adding a backend is one case in the composition root, not a change to every consumer.

Tests replace the provider with an in-memory dictionary, which is how key rotation, the
absent-keyset cases, and every job test run without touching a live vault. That second
implementation is what justified the seam.

Resolved values are wrapped in a type that redacts description, debug output, and reflection.
Reading the real value is an explicit call, deliberately awkward.

Switching backends does not migrate values. The same names must be provisioned in the destination
first, and the previous backend kept available through the rollback window.

Read-only backends do not fit the three-operation contract cleanly. Adding one requires either a
documented unsupported-operation error or splitting the contract.

#icicle-insights# #Explanation# #Developer# #decisions# #credentials#
