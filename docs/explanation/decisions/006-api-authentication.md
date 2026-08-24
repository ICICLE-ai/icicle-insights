# ADR 006: Two credential paths, one guard

**Status:** Accepted

## Context

Insights is a public dashboard whose writes must be guarded. Two very different callers need to
write: people administering the catalog from the browser, and deployed ICICLE services reporting
their own metrics.

An earlier design used opaque tokens in a vault registry with a capability enumeration, and
forbade minting over HTTP. Both were reversed.

## Decision

Accept two bearer credentials.

- **Tapis JWTs** for people, verified locally against the tenant public key fetched at boot, with
  the token's tenant claim compared against the configured tenant.
- **Self-minted webhook tokens** for services, scoped to exactly one resource, expiring after a
  chosen lifetime that defaults to 90 days, and revocable.

Both authenticators run on every request and **neither rejects anything**. A single `Require`
middleware, attached per route inside each controller, produces every 401 and 403.

Administrators are the configured root plus an `admins` table managed from the console.

Minting is available over HTTP to administrators, as well as from the CLI.

## Consequences

Non-rejecting authenticators are what keep public reads working. Rejecting an unrecognised bearer
inside an authenticator would fail anonymous requests before they reached a public route.

`Require`'s predicate is synchronous and cannot query, so admin status is resolved during
authentication and carried on the identity. Revocation takes effect on the next request rather than
at the next restart, at the cost of one indexed lookup per authenticated request.

Resource scoping replaced the capability enumeration. A token's binding lives inside its signature,
so the holder cannot widen it, and one route is all a service can reach.

Webhook tokens still need a database row, because a JWT cannot express revocation. The row holds an
identifier and metadata, never a credential, and is resolved uncached on every request — caching
would delay revocation, which is the only reason the row exists.

Allowing HTTP minting means a leaked administrator token could mint credentials. That is why the
minting routes are administrator-only and why service tokens can never mint another.

The tenant comparison is load-bearing. A valid signature proves a token is genuine, not which tenant
issued it; without the check, an administrator of any other Tapis tenant would be an administrator
here.

#icicle-insights# #Explanation# #Developer# #decisions# #security#
