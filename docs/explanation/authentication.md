# Authentication

Two kinds of caller, one place that says no. For administrators and developers.

**Reads are public.** Insights is a public dashboard, so anonymous callers can read accounts,
resources, releases, and metrics. Everything that writes is guarded, plus vault and service-token
reads, because listing which credentials exist is reconnaissance.

## Two credential paths

| Caller | Credential | May do |
|---|---|---|
| A person on the dashboard | Tapis JWT | Everything, if an administrator |
| A deployed service | A webhook token this server minted | Post metrics for exactly one resource |

Both authenticators run on every `/api` request and **neither rejects anything**. Each recognises
its own kind of bearer value and logs in that identity, or returns quietly.

That is the design decision that keeps public reads working. If an authenticator rejected an
unrecognised token, an anonymous request would fail before reaching a public route. Instead,
`Require` — attached per route inside each controller — decides who may proceed, and is the only
place 401 and 403 come from.

## People

`TapisAuthenticator` verifies the bearer against the tenant's RSA public key, fetched once at boot
from the tenant record. Verification is local: no round trip to Tapis on the request path, and the
caller's token is never forwarded anywhere.

Identity comes from the token's own claims rather than from a userinfo call, which does not return
the tenant.

**The tenant claim is checked against `TAPIS_TENANT`, and that check is not optional.** A valid
signature proves the token is genuine, not which tenant issued it. Without the comparison, an
administrator of any other Tapis tenant would be an administrator here.

Fetching the key rather than pinning it in source means a Tapis key rotation costs a restart
instead of every request failing 401 with nothing in the log to explain it.

### The tenant PEM

Tapis publishes the public key as a single unwrapped base64 line. RFC 7468 requires 64-character
lines and SwiftASN1 enforces it, so the key as published cannot be parsed. `TapisClient` re-wraps
it before use.

Worth knowing because no test caught it. The testing environment skips the fetch entirely, so it
appeared only on a real boot, where it crashed the process.

## Who is an administrator

Two sources.

| Source | Notes |
|---|---|
| `ROOT_ADMIN_USERNAME` | One username, always an administrator. Cannot be removed through the API |
| The `admins` table | Everyone else. Granted and revoked from the console |

The root exists as a recovery path. Administrators are managed from the console, so deleting the
last row would otherwise lock everyone out of the screen needed to fix it.

Resolution happens during *authentication*, not inside `Require`. `Require`'s predicate is
synchronous and cannot reach the database, so admin status is looked up once per authenticated
request and carried on the identity. Revocation therefore takes effect on the next request rather
than at the next restart.

`ROOT_ADMIN_USERNAME` must be a real username in the configured tenant. A placeholder boots
perfectly well and matches nobody, so every write returns 403 with nothing explaining it.

## Services

A deployed service reports its own metrics with a token scoped to one resource. It holds nothing
else: no Tapis identity, no vault access.

The resource binding and the expiry live **inside the signature**, so neither can be widened by the
holder. Tokens are signed HS256, because the same process mints and verifies them and an
asymmetric key would buy nothing.

### Why there is still a database row

A JWT gives expiry and the resource binding for free. It cannot give revocation.

So `service_tokens` holds an identifier, the resource, a label, the expiry, and a revocation
timestamp, and every request resolves that identifier against a live row. **The row holds no
credential.**

Order matters. Signature and expiry are checked first, which rejects Tapis tokens and noise without
touching PostgreSQL; the lookup runs only for a token this server actually minted. The lookup is
deliberately not cached, because caching it would delay revocation, which is the only reason the
row exists.

### Their own key collection

Webhook signing keys live in a separate `JWTKeyCollection`, never the application's main one.

Sharing one collection across two trust domains is a correctness bug waiting to happen. JWTKit
falls back to the default signer when a `kid` is unknown, and Tapis tokens carry a `kid` this
server never registers. A legitimate administrator would be verified against the HMAC key and
rejected.

## Bootstrapping

The signing keyset must be created once per deployment, and staging and production are separate
vaults — a keyset made against one does not carry over.

Until it exists the service runs with an empty keyset. Webhook authentication recognises nobody,
while administrator access, public reads, and collection are unaffected. It is logged at
`critical` on every boot, naming the command.

**This is deliberately survivable rather than fatal.** Every command routes through `configure`, so
failing hard would take down the very command that creates the keyset, and a fresh deployment could
never be bootstrapped.

A read that is *refused* rather than absent still aborts the boot. A 401 means the Tapis service
credentials are wrong, which breaks every collection job, and must not be mistaken for a deployment
that simply has not been set up yet.

## Why not cookies

The server reads `Authorization: Bearer` and nothing else. Cookies were considered and rejected
for two reasons.

1. **Cookies are scoped by domain, not by frame.** Served from a different registrable domain than
   an embedding page, the browser never sends that page's cookie here. The feature would silently
   do nothing.
2. **Cookie credentials are CSRF-exposed by construction**, since browsers attach them
   automatically. Every mutating route would need a companion defence. Bearer headers are immune
   because a browser never adds them unprompted.

A dashboard embedded in another application obtains the token from its parent, holds it in memory,
and attaches it as a header. See [The dashboard](the-dashboard.md).

#icicle-insights# #Explanation# #Administrator# #Developer# #security#
