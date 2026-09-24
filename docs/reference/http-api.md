# HTTP API

Every route the server answers, who may call it, and the rules it enforces. For developers and
integrators. The live, generated reference is at `/docs`, from the document at `/openapi.json`.

## Conventions

| Topic | Rule |
|---|---|
| Base path | `/api` for everything except probes, docs and the dashboard |
| Format | JSON. Dates are ISO 8601. Days in query strings are `YYYY-MM-DD`, UTC |
| Authentication | `Authorization: Bearer <token>`: a Tapis token for administrators, or a service token |
| Unauthenticated | `401` on a route that needs a caller |
| Not permitted | `403` for a recognised caller without permission |
| Rate limit | 300 requests a minute per client address across `/api`. `429` with `Retry-After` beyond it |
| Request ID | Send `X-Request-ID` to set one; every response carries it back |

**Who** below: *Public* needs no token. *Admin* needs an administrator's Tapis token. *Admin or
service* also accepts the service token issued for that resource.

## Summaries

| Method | Path | Who | Parameters |
|---|---|---|---|
| GET | `/api/insights/summary` | Public | `from`, `to`, `platform`, `resourceID` |
| GET | `/api/insights/series` | Public | The above, plus `type` (required), `bucket` (`day` or `week`), `groupBy` (`none` or `platform`) |
| GET | `/api/insights/resources` | Public | The above range filters, plus `sort` (metric id, default `stars`), `order` (`desc` or `asc`), `limit` (1–500, default 50), `offset`, `kind` |

`to` defaults to today, and a later day counts as today. `from` defaults to 90 days before `to`. A
range may span at most 731 days.

## Catalog

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/accounts` | Public | |
| POST | `/api/accounts` | Admin | `name`, `platform`. Name stored lowercase; unique per platform |
| GET | `/api/accounts/{id}` | Public | |
| PATCH | `/api/accounts/{id}` | Admin | `followers` |
| DELETE | `/api/accounts/{id}` | Admin | `409` while it has resources or a credential |
| GET | `/api/resources` | Public | Includes Patra card details and cross-registry `links` |
| POST | `/api/resources` | Admin | `name`, `type`, `accountID`, optional `collectionIntervalDays`. Collected at once |
| GET | `/api/resources/{id}` | Public | |
| PATCH | `/api/resources/{id}` | Admin | `name`, `type`, `collectionIntervalDays` |
| DELETE | `/api/resources/{id}` | Admin | Soft delete; history is kept |
| GET | `/api/releases` | Public | |
| POST | `/api/releases` | Admin | `resourceID`, `version`, `month`, `year` (1970–2100) |
| GET | `/api/releases/{id}` | Public | |
| PATCH | `/api/releases/{id}` | Admin | `version`, and `month` with `year` together |
| DELETE | `/api/releases/{id}` | Admin | |

## Metrics

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/metrics` | Public | `resourceID`, `type`, `limit` (1–1000, default 1000). The newest readings, returned oldest first |
| POST | `/api/metrics` | Admin | `resourceID`, `type`, `reading` (0 or more). Not a lifetime type |
| POST | `/api/resources/{id}/metrics` | Admin or service | `type`, `reading`. 60 requests a minute per service token |
| GET | `/api/metrics/{id}` | Public | |
| PATCH | `/api/metrics/{id}` | Admin | `reading`, `type` |
| DELETE | `/api/metrics/{id}` | Admin | |

A recorded, corrected or deleted reading of a windowed type also moves its lifetime total.

## Administration

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/vaults` | Admin | Names and expiry dates; never secret values |
| POST | `/api/vaults` | Admin | `accountID`, `token`, `expires` (`day`, `month`, `year`). Writes the secret to Tapis Vault |
| GET | `/api/vaults/{id}` | Admin | |
| PATCH | `/api/vaults/{id}` | Admin | `token`, `expires` |
| DELETE | `/api/vaults/{id}` | Admin | Also destroys the secret in Tapis Vault |
| GET | `/api/admins` | Admin | The console uses it to check a sign-in |
| POST | `/api/admins` | Admin | `username`. `409` if already an administrator |
| DELETE | `/api/admins/{id}` | Admin | `403` for the root administrator |
| GET | `/api/service-tokens` | Admin | Every token issued, without values |
| POST | `/api/service-tokens` | Admin | `resourceID`, `label`, `expiresInDays` (1–365, default 90). Returns the token once |
| POST | `/api/service-tokens/{id}/revoke` | Admin | |
| POST | `/api/service-tokens/rotate-key` | Admin | Returns the new `activeKid` |
| GET | `/api/admin/queues` | Admin | Queue depth and scheduler heartbeat |
| GET | `/api/admin/failures` | Admin | `limit` (1–200, default 50) |
| GET | `/api/admin/watermarks` | Admin | |

## Outside `/api`

| Method | Path | Answers |
|---|---|---|
| GET | `/health` | `{"status":"ok"}` while the process runs |
| GET | `/ready` | `{"status":"ready"}` when PostgreSQL and Valkey both answer, otherwise `503` |
| GET | `/openapi.json` | The OpenAPI document |
| GET | `/docs` | The interactive API reference |
| GET | `/dashboard` | Permanent redirect to `/` |
| GET | anything else | The dashboard, or `404` for unknown `/api` paths and missing files |

Probes are not rate limited.

#icicle-insights# #Reference# #Developer#
