# Data model

Tables, relationships, and enumerations. For developers.

```mermaid
erDiagram
    ACCOUNT ||--o{ RESOURCE : owns
    ACCOUNT ||--o| VAULT : references
    RESOURCE ||--o{ METRIC : records
    RESOURCE ||--o{ RELEASE : publishes
    RESOURCE ||--o{ METRIC_WATERMARK : tracks
    RESOURCE ||--o{ SERVICE_TOKEN : authorizes
```

## Tables

| Table | Holds |
|---|---|
| `accounts` | Platform identities that own resources |
| `resources` | The things being measured, and their collection cadence |
| `metrics` | Individual readings, one row per sweep per metric |
| `metric_watermarks` | Newest completed day already folded into an all-time total |
| `releases` | Published versions |
| `vaults` | References to credentials stored outside PostgreSQL |
| `service_tokens` | Webhook token identifiers and metadata |
| `admins` | Granted administrator access |
| `job_failures` | Durable record of failed collection jobs |

## Key fields

**`resources`**

| Field | Meaning |
|---|---|
| `next_collection_at` | When this resource may next be dispatched. Null means never |
| `collection_interval_days` | Spacing booked after a successful dispatch. Default 7 |

**`metric_watermarks`** — one row per `(resource, metric type)`.

| Field | Meaning |
|---|---|
| `counted_through` | Newest completed UTC day already added to the all-time total |

`next_collection_at` and `counted_through` answer different questions: *when to fetch next* versus
*what has already been counted*. Keeping them apart is what lets a late sweep resume exactly where
the last one stopped.

**`service_tokens`**

| Field | Meaning |
|---|---|
| `jti` | Random token identifier. Resolved against a live row on every request |
| `label` | Human name for the token |
| `expires_at` | Set at minting from the chosen lifetime. Default 90 days, range 1–365 |
| `revoked_at` | Set on revocation. The row is retained as an audit trail |

**The row holds no credential.** Identifiers and metadata only.

## Enumerations

**Platform** — on `accounts`, and what collection routes on.

```
github  ghcr  huggingface  npm  pypi
```

**Resource kind** — on `resources`. Describes what a thing is, not which API reports on it.

```
container  dataset  model  package  repository  service
```

Only a resource of kind `service` can be issued a webhook token.

**Metric type** — on `metrics`.

```
authentications  clones  downloads  forks  likes  pulls  stars  subscribers  views
authenticationsAllTime  clonesAllTime  downloadsAllTime  pullsAllTime  viewsAllTime
```

The `*AllTime` variants cannot be written directly through the API. They are maintained by the
fold. See [Watermarks](../explanation/watermarks.md).

## Migrations

Applied in order, all registered in `configure.swift`.

| Migration | Adds |
|---|---|
| `FirstMigration` | Accounts, resources, metrics, releases, vaults |
| `RecurringCollection` | Collection due dates and watermarks |
| `ServiceTokens` | Webhook token rows |
| `Admins` | Granted administrator access |
| `JobFailures` | Durable failure records |
| `ICICLESnapshotJuly2026` | Seed data. **Development only** |

The seed migration is registered only when `VAPOR_ENV=development`, so it targets `dev` and can
never reach `test` or a deployment.

## Database by environment

| Environment | Database |
|---|---|
| testing | `test` |
| development | `DATABASE_NAME`, else `dev` |
| production | `DATABASE_NAME`, else `vapor_database` |

Tests always hit `test`, so a stray run cannot clobber development or production data.

#icicle-insights# #Reference# #Developer# #data-model#
