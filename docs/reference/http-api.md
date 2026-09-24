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
| `/api/insights/summary`, `/api/insights/series`, `/api/insights/resources` | `GET` | public |
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
| `GET` | `/api/insights/summary` | public |
| `GET` | `/api/insights/series` | public |
| `GET` | `/api/insights/resources` | public |
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
| 409 | Conflict, such as a duplicate vault name for one account, or deleting an account that still owns resources or a credential |
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

### Insights

The three `/api/insights` routes total readings in the database and have no row cap. All accept
these, all optional.

| Parameter | Type | Notes |
|---|---|---|
| `from` | `YYYY-MM-DD` | First UTC day. Defaults to 90 days before `to` |
| `to` | `YYYY-MM-DD` | Last UTC day, inclusive. Defaults to today; a later day is read as today |
| `platform` | platform | Only resources whose account is on it |
| `resourceID` | UUID | Only this resource |

`from` must not be after `to`, and they may be at most 731 days apart. Anything else is a 400.
Soft-deleted resources, and resources of soft-deleted accounts, are never counted.

`GET /api/insights/series` adds:

| Parameter | Values | Notes |
|---|---|---|
| `type` | metric type | **Required** |
| `bucket` | `day`, `week` | Default `day`. A week's point is its last day inside the range |
| `groupBy` | `none`, `platform` | Default `none`, one group keyed `all`. Otherwise keyed by platform |

`GET /api/insights/resources` adds:

| Parameter | Values | Notes |
|---|---|---|
| `sort` | metric type | Default `stars`. Ranks on each resource's latest value |
| `order` | `asc`, `desc` | Default `desc`. Resources without the metric sort last either way |
| `limit` | 1–500 | Default 50 |
| `offset` | 0 or more | Default 0 |
| `kind` | resource kind | Only resources of this kind |

### Insights responses

Every series is carried forward: a resource's value on a day is its latest reading by that day's
end, and a group's is the sum over its resources. A series starts on the first day anything in it
has a value, then has one point per day. Points are `{ "t": "YYYY-MM-DD", "v": number }`.

| Route | Returns |
|---|---|
| `summary` | `generatedAt`, `from`, `to`, and one tile per metric type with data in scope |
| `series` | `type`, `bucket`, and `groups`, each a `key` and its `points` |
| `resources` | `total` in scope before paging, and `rows` |

| Tile field | Meaning |
|---|---|
| `type` | Metric type |
| `kind` | `lifetime` for the `*AllTime` types, `window` for `clones`, `views`, `downloads`, `authentications`, `pulls`, `gauge` for the rest |
| `current` | Sum of each resource's latest value, whatever the range |
| `atStart` | The same sum at the end of `from`. `null` when nothing had a value by then |
| `series` | Daily points from the first day with data through `to` |

A `lifetime` tile's `atStart` and `series` come from daily snapshots that begin when
`metric_daily_totals` was deployed. Before that they are `null` and empty. See
[Metric history](../explanation/metric-history.md).

| Row field | Meaning |
|---|---|
| `id`, `name`, `kind`, `platform`, `account` | The resource, its kind, and its account's platform and name |
| `lastCollectedAt` | Last successful collection, or `null` |
| `latest` | Metric type to latest value, for every type the resource has |
| `atStart` | Metric type to value at the end of `from`, for every type that had one |
| `spark` | The `sort` metric's daily points in the range |

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
