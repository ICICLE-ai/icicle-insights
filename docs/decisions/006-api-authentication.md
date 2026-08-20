# ADR 006: Two credential paths, one requirement check

**Status:** Accepted

Humans present a Tapis JWT, verified locally against the tenant public key fetched at boot; a
`tapis/tenant_id` comparison rejects a correctly signed token from another tenant. Deployed
services present a JWT this server mints, signed HS256 with a key held in Vault, carrying an
expiry and the one resource it may post metrics for — both inside the signature, so neither can
be widened by the holder. Revocation cannot live in the token, so a `service_tokens` row keyed by
`jti` is resolved on every request; it holds no credential, only an identifier and metadata.
Minting revokes any live token for the same resource, keeping one working credential per resource.

Neither authenticator rejects anything — each logs in its identity or returns quietly, leaving
reads open to anonymous callers — and a single `Require` middleware decides per route, emitting
401 when nobody authenticated and 403 when someone did but lacks permission. Admins are checked
first. `ServiceTokenIssuer` is the only place tokens are minted, revoked, or listed; the CLI and
the admin-only HTTP routes are both wrappers over it.

Superseded here: capabilities carried per opaque token in a Vault registry, and minting kept off
HTTP entirely. Scoping to one resource replaced grants outright, and these tokens are narrow
enough — one resource, one route, expiring, revocable — that an attacker reaching the mint
endpoint already holds admin and could write those metrics directly.

#icicle-insights# #architecture-decision# #authentication# #middleware# #tapis# #security#
