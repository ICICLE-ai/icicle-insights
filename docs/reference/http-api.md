# HTTP API

Routes, guards, and conventions. For administrators and developers.

The generated OpenAPI document is the source of truth for individual routes.

| URL | Serves |
|---|---|
| `/docs` | Browsable API reference |
| `/openapi.json` | The generated document |

## Guards

Reads are public. Writes are guarded. Vault and service-token reads are guarded too, because
listing which credentials exist is reconnaissance.

| Routes | Methods | Guard |
|---|---|---|
| `/api/accounts`, `/api/resources`, `/api/releases`, `/api/metrics` | `GET` | public |
| `/api/accounts`, `/api/resources`, `/api/releases`, `/api/metrics` | `POST`, `PATCH`, `DELETE` | admin |
| `/api/resources/:resourceID/metrics` | `POST` | resource-scoped token, or admin |
| `/api/vaults` | all, reads included | admin |
| `/api/service-tokens` | all | admin |
| `/api/admins` | all | admin |
| `/api/admin/watermarks`, `/api/admin/queues`, `/api/admin/failures` | `GET` | admin |
| `/health`, `/ready` | `GET` | public, and outside `/api` |

`POST /api/resources/:resourceID/metrics` is the only route a non-human can reach. Administrators
are checked first within it, so a person is never locked out of a route a service can use.
Deletes are admin-only everywhere: a malfunctioning service should at worst write bad rows, never
remove history.

## Full route list

| Method | Path | Guard |
|---|---|---|
| `GET` | `/api/accounts` | public |
| `POST` | `/api/accounts` | admin |
| `GET` | `/api/accounts/:accountID` | public |
| `PATCH` | `/api/accounts/:accountID` | admin |
| `DELETE` | `/api/accounts/:accountID` | admin |
| `GET` | `/api/resources` | public |
| `POST` | `/api/resources` | admin |
| `GET` | `/api/resources/:resourceID` | public |
| `PATCH` | `/api/resources/:resourceID` | admin |
| `DELETE` | `/api/resources/:resourceID` | admin |
| `POST` | `/api/resources/:resourceID/collect` | admin |
| `GET` | `/api/releases` | public |
| `POST` | `/api/releases` | admin |
| `GET` | `/api/releases/:releaseID` | public |
| `PATCH` | `/api/releases/:releaseID` | admin |
| `DELETE` | `/api/releases/:releaseID` | admin |
| `GET` | `/api/metrics` | public |
| `POST` | `/api/metrics` | admin |
| `GET` | `/api/metrics/:metricID` | public |
| `PATCH` | `/api/metrics/:metricID` | admin |
| `DELETE` | `/api/metrics/:metricID` | admin |
| `POST` | `/api/resources/:resourceID/metrics` | resource-scoped |
| `GET` | `/api/vaults` | admin |
| `POST` | `/api/vaults` | admin |
| `GET` | `/api/vaults/:vaultID` | admin |
| `PATCH` | `/api/vaults/:vaultID` | admin |
| `DELETE` | `/api/vaults/:vaultID` | admin |
| `GET` | `/api/service-tokens` | admin |
| `POST` | `/api/service-tokens` | admin |
| `POST` | `/api/service-tokens/:tokenID/revoke` | admin |
| `POST` | `/api/service-tokens/rotate-key` | admin |
| `GET` | `/api/admins` | admin |
| `POST` | `/api/admins` | admin |
| `DELETE` | `/api/admins/:adminID` | admin |
| `GET` | `/api/admin/watermarks` | admin |
| `GET` | `/api/admin/queues` | admin |
| `GET` | `/api/admin/failures` | admin |

## Credentials

Send the token in the header. Cookies are never read.

```
Authorization: Bearer <token>
```

Two token kinds are accepted. See [Authentication](../explanation/authentication.md).

| Token | Held by | May do |
|---|---|---|
| Tapis JWT | A person on the dashboard | Everything, if an administrator |
| Webhook token | A deployed service | Post metrics for exactly one resource |

## Status codes

| Code | Means |
|---|---|
| 401 | Nobody authenticated. Absent, malformed, expired, or foreign-tenant token |
| 403 | Authenticated, but not permitted |
| 409 | Conflict, such as a duplicate vault name for one account |
| 429 | Rate limited. Honour `Retry-After` |
| 502 | An upstream Tapis failure, not the caller's fault |
| 503 | Not ready, or minting attempted with no signing keyset |

A 401 never says *why* the credential failed. That is deliberate; the reason is in the server log,
correlated by request ID.

## Query parameters

`GET /api/metrics` accepts three, all optional.

| Parameter | Type | Notes |
|---|---|---|
| `resourceID` | UUID | Restrict to one resource |
| `type` | metric type | See [Data model](data-model.md) |
| `limit` | 1–1000 | Defaults to 1000 |

The newest `limit` rows are selected, then returned **oldest first**, which is chart x-axis order.

## Conventions

- Timestamps are ISO 8601, UTC.
- Identifiers are UUIDs.
- Every response carries `X-Request-ID`. Quote it in a bug report.
- An inbound `X-Request-ID` is honoured and echoed, so a client can correlate its own trace.
  Values are limited to letters, digits, `-` and `_`, at most 64 characters. Anything else is
  replaced, because the header reaches log metadata verbatim.

## Discovering administrator status

There is no `/me` route. Attempt an admin-only read.

```
GET /api/admins
  200  the caller is an administrator
  403  authenticated, not an administrator
  401  no usable credential
```

The distinction matters in a UI: 403 means "signed in, not permitted" and 401 means "not signed
in". They call for different messages.

#icicle-insights# #Reference# #Administrator# #Developer# #api#
