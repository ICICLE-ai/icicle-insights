# ADR 007: Headers, limits, and live key rotation

**Status:** Accepted

## Context

The service is publicly reachable and embedded in another application. It needs response hardening,
abuse limits, and a way to roll the webhook signing key without taking every deployed service
offline.

## Decision

Register CORS, security headers, and request-ID middleware at the beginning of the chain, ahead of
the error middleware.

Rate limit per client address across the API, and per token on the metric-reporting route, using
Valkey counters. The limiter **fails open**.

Store webhook signing keys as a keyset with key identifiers, so rotation adds a key rather than
replacing one.

Make the framing allowlist explicit and deny framing by default.

## Consequences

Placement is the part that regresses silently. Response headers are stamped on the way back out, so
a middleware registered after the error middleware never sees an error response — and a 4xx with no
CORS headers is unreadable to the browser that caused it, which is exactly when reading it matters.
There are tests asserting headers on errors, not just on success.

Failing open is a deliberate availability trade. A limiter that takes the API down together with its
counter store causes more harm than the abuse it prevents. A test asserts that an unreachable
counter store still serves traffic.

Sharing Valkey with the queues means limits hold across replicas rather than being granted afresh by
each one.

Rotation is additive and needs no restart: every key registers under its identifier and new tokens
are signed with the active one, so tokens issued beforehand keep verifying until they expire. Keys
older than the longest possible token lifetime are dropped rather than accumulating. The destructive
alternative remains available behind an explicit flag.

Only a restart proves a retired key was persisted rather than merely still in memory. That case is
exercised by hand, not by the suite.

Unset, the framing allowlist sends both a legacy deny header and a CSP directive. Setting it omits
the legacy header entirely, because that header has no allowlist form and could then only contradict
the CSP. Malformed entries are dropped with a warning rather than passed through, because a policy
the browser rejects wholesale fails *open* on framing.

Inbound request IDs are constrained and replaced when implausible, because the value reaches log
metadata verbatim.

A full Content-Security-Policy is deliberately not shipped. It needs the bundle's asset origins
settled, and a wrong policy breaks the application rather than degrading it.

#icicle-insights# #Explanation# #Developer# #decisions# #security#
