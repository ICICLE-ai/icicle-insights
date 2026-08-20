# ADR 007: CORS, rate limits, headers, and live key rotation

**Status:** Accepted

CORS comes from a `CORS_ORIGINS` allowlist and is absent when unset, since public reads make
browsers on other ICICLE origins the expected consumer rather than a hypothetical one. It and the
security headers register `at: .beginning`, ahead of `ErrorMiddleware`, because response headers
are applied on the way out and an error response without CORS headers is unreadable to the
browser that caused it. Rate limits are Redis fixed windows over the Valkey queues already use —
per client IP on `/api`, per token on the webhook route — and fail open, because a limiter that
takes the API down with its counter store causes more harm than the abuse it prevents.

The webhook signing secret became a keyset addressed by `kid`, so rotation adds a key to the live
collection instead of replacing it: tokens issued beforehand keep verifying until they expire, and
no restart is involved. Admins moved from an environment allowlist to a table managed from the
dashboard, with `ROOT_ADMIN_USERNAME` retained as a permanent break-glass identity so an emptied
table cannot lock anyone out. Admin status resolves during authentication rather than in
`Require`, whose predicate is synchronous.

Rejected: `kid` routing against a Tapis JWKS. Discovery works, but the published `jwks_uri` points
back at the tenant record, which serves one PEM rather than a key set — there is nothing to route
between. Also rejected: deriving admins from Tapis's `admin_user` or Security Kernel roles, which
describe who administers the Tapis tenant, not who may mutate ICICLE's metrics.

#icicle-insights# #architecture-decision# #security# #cors# #rate-limiting# #middleware#
