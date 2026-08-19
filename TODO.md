# TODO — Middleware, Auth, and Frontend

Working notes for the `middlewares` branch. The rationale behind each decision is recorded so it
doesn't get re-litigated — including for the several that were later reversed, where the reversal
and its reason are written down rather than edited away. Full detail in
[`docs/api-authentication.md`](docs/api-authentication.md) and ADRs 006 and 007.

## Decisions

| Question | Decision |
|---|---|
| Auth mechanism | Tapis JWT, verified locally against the tenant public key fetched at boot |
| Webhook tokens | Self-minted JWTs, scoped to one resource, 90-day expiry, revocable |
| Admin storage | `ROOT_ADMIN_USERNAME` break-glass + `admins` table, managed from the dashboard |
| Read access | Public — the dashboard is a public site; writes are guarded |
| API namespace | API under `/api`, Angular SPA at root |
| Frontend hosting | Served by Vapor from `Public/` — one pod, no nginx |
| CORS | `CORS_ORIGINS` allowlist; unset means no CORS middleware at all |
| Rate limits | Redis-backed: per-IP on `/api`, per-token on the webhook route. Fails open |

## Work items

### 1. Tapis auth middleware + admin guard ✅

- [x] Tenant public key fetched at boot (`TapisClient+Auth.swift`), registered into `app.jwt.keys`
- [x] `TapisAuthenticator` verifies locally; no round trip on the request path
- [x] `tapis/tenant_id` compared against `TAPIS_TENANT`, so a valid token from another Tapis
      tenant can't authenticate here
- [x] Webhook tokens reach exactly one route; everything else is admin-only
- [x] `ROOT_ADMIN_USERNAME` read at boot; fails fast when absent
- [x] `Require` returns 403 for an authenticated caller lacking the grant, 401 when nobody
      authenticated — one middleware, since either identity may satisfy a shared route
- [x] Validation caching — moot, local verification has no round trip to amortize

### 2. `/api` namespace ✅

- [x] Group the five resource controllers under `api` in `routes.swift`
- [x] `DashboardController`, `/openapi.json`, and `/docs` stay at root
- [x] No `servers:` change needed — `VaporToOpenAPI` reflects off `app.routes`, so paths
      become `/api/...` automatically

### 3. Re-enable mutating routes ✅

- [x] Every mutating route on `Account`, `Resource`, `Metric`, `Release` is `Require.admin`
- [x] `VaultController` — all five routes admin-only, reads included
- [x] Protected routes marked `.openAPI(auth: .bearer())`
- [x] **Answered:** yes. Vault is admin-only throughout, reads as well as mutations. No service
      needs it — jobs resolve secrets in-process through `SecretProvider`, never over HTTP — and
      the metadata alone enumerates which credentials exist and when they expire.

### 3b. Webhook tokens ✅

Each deployed ICICLE service reports its own metrics with a token bound to its resource.

- [x] `ServiceToken` model and additive `ServiceTokens` migration, `resource_id` cascading
- [x] `WebhookToken` claims: `iss`, `jti`, `iat`, `exp`, `insights/resource_id`
- [x] HS256, signing key in Vault, in its **own** `JWTKeyCollection` — never `app.jwt.keys`,
      where an unknown Tapis `kid` would fall back to the HMAC signer and reject real admins
- [x] `ServiceTokenIssuer` is the single home for mint/revoke/list; CLI and controller wrap it
- [x] `POST /api/resources/:resourceID/metrics` behind `Require.resourceScoped`
- [x] Revocation is a live per-request `jti` lookup — immediate, no restart
- [x] Minting revokes any live token for the same resource, in one transaction
- [x] Admin-only `ServiceTokenController` so the dashboard can mint, list, and revoke
- [x] `service-token init-key | rotate-key | issue | revoke | list`

**Superseded:** the opaque-token Vault registry and the `Capability` enum are gone. Resource
scoping replaced grants; see `docs/decisions/006-api-authentication.md` for why both that and the
"no HTTP minting" rule were reversed.

### 3c. Hardening ✅

- [x] CORS from a `CORS_ORIGINS` allowlist, registered `at: .beginning` so error responses carry
      the headers too — a 4xx without them is unreadable to the browser that caused it
- [x] `SecurityHeadersMiddleware`: `nosniff`, `Referrer-Policy`, `X-Frame-Options`, HSTS in prod
- [x] `RateLimiter`, Redis-backed fixed window; per-IP on `/api`, per-token on the webhook route.
      Fails open — a limiter that takes the API down with its counter store is worse than the
      abuse it prevents
- [x] Signing keyset with `kid`s, so `service-token rotate-key` adds a key rather than replacing
      one; tokens issued before a rotation keep verifying until they expire
- [x] `admins` table plus `AdminController`; admin status resolved during authentication, since
      `Require`'s predicate is synchronous and cannot reach the database
- [x] **Fixed a boot-blocking bug only a live run found:** Tapis returns the tenant PEM as one
      unwrapped line, which SwiftASN1 rejects for RFC 7468 line lengths. Every production boot
      would have crashed on `invalidPEMDocument`. Now re-wrapped, with a regression test.

### 4. Angular frontend

- [ ] Node build stage in the `Dockerfile`; output copied into `Public/`. Lines 55-57 already
      stage `/build/Public` into the runtime image, so no change to the staging logic.
- [ ] SPA fallback: catchall serving `index.html` for deep links. Safe because Vapor's router
      prefers constant path components, so `/api/*`, `/docs`, and `/openapi.json` still win.
- [ ] Cache headers: immutable + long max-age for hashed bundles, no-cache for `index.html`,
      or clients pin to a stale bundle referencing deleted files.
- [ ] Decide the fate of the Leaf dashboard (`DashboardController`) and the existing
      `Public/dashboard.css` / `dashboard.js` — replaced by Angular, or coexisting under
      `Public/app/` during a transition?
- [ ] Dev loop: `ng serve` on :4200 with `proxy.conf.json` forwarding `/api` → :8080.
      Alternative is `ng build --watch` into `Public/` — no HMR, but dev matches prod.

### 5. Request ID middleware

- [ ] Stamp a UUID into `req.logger` metadata, propagate into job payloads, include in
      `SlackNotifier` alerts. Right now a failure alert can't be traced to the request that
      enqueued it. Return it in a response header so frontend bug reports carry it.

### 6. Docs ✅

- [x] `docs/decisions/006-api-authentication.md` — two credential paths, one requirement check
- [x] `docs/decisions/007-hardening.md` — CORS, rate limits, headers, live key rotation
- [x] `docs/api-authentication.md` rewritten for the built design, with each departure from the
      original draft called out in place
- [x] `.env.example`: `ROOT_ADMIN_USERNAME`, `CORS_ORIGINS`, rate limits, `TOKEN_SIGNING_SECRET`

### 7. Before this deploys

Not blockers for the branch, but none of these can be checked without real Tapis credentials —
the test suite runs with dummy ones and `.testing` skips every network call.

- [ ] Set `ROOT_ADMIN_USERNAME` in the deployed environment. **`ADMIN_USERNAMES` no longer does
      anything**, and boot fails outright without the new one.
- [ ] Confirm `TAPIS_BASE_URL` carries `/v3` and `TAPIS_TENANT` is `icicleai`. `.env.example`
      still shows `icicle` and no `/v3`; a real token says otherwise, and a wrong tenant means
      every admin is silently refused.
- [ ] `swift run Insights service-token init-key`, then restart. Nothing can be minted or
      verified until this exists.
- [ ] Run the three `VaultControllerTests` that need live Tapis — they fail here on dummy
      credentials, and they write and destroy real secrets when they pass.
- [ ] Check `/openapi.json` reflects the bearer scheme onto the guarded routes.
- [ ] **Exercise a rotation by hand**: mint, post a metric, `rotate-key`, confirm the original
      token still works. This is what the keyset design exists for and the one path no test
      covers end to end.

### 8. Known gaps

- [ ] **Nothing warns before a webhook token expires.** At 90 days a service's metrics simply
      stop arriving, with no error anyone sees. `SlackNotifier` already exists; a scheduled sweep
      warning at ~14 days out is small and prevents a class of "why did that chart stop in
      November" investigations.
- [ ] `SyncJobTests` — "Each repo kind is fetched from its own segment" asserts
      `url.contains("expand[]=downloads")` but Vapor percent-encodes the brackets. Pre-existing,
      unrelated to auth, still failing.

## Deferred — deliberately not doing

- **CSP** — genuinely needs the Angular bundle's asset origins settled; a wrong policy breaks the
  app rather than degrading it. The headers that depend on nothing (`nosniff`, `Referrer-Policy`,
  `X-Frame-Options`, HSTS) already ship in `SecurityHeadersMiddleware`.
- **Tapis `kid` routing / JWKS** — **not possible as Tapis is deployed.** Discovery works, but
  `/v3/oauth2/.well-known/oauth-authorization-server` returns a `jwks_uri` pointing back at
  `/v3/tenants/{tenant}`, which serves a single PEM rather than a key set. There is nothing to
  route a `kid` against. Revisit only if Tapis starts publishing a real JWKS.
- **Webhook token renewal** — tokens expire at 90 days and are replaced by minting a new one and
  updating the deployment secret. Self-renewal is the tempting shortcut and the wrong one: a
  leaked token that can renew itself never expires, which removes the only thing expiry buys.
- **Angular SSR** — needs Node at runtime, so a second pod or Node in the runtime image. Worth
  reconsidering now that the dashboard is public rather than authed: the original rationale ("no
  SEO or cold-load pressure on an authed dashboard") no longer holds, even if the conclusion may.
- **Response compression** — the K8s ingress may already handle it. Nobody has checked; this is
  an open question rather than a decision.
- **Finer rate limiting** — per-IP on `/api` and per-token on the webhook route are in. Per-route
  budgets and burst allowances wait for evidence that the flat limits are wrong.
