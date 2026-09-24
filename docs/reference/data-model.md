# Data model

The PostgreSQL tables Insights keeps, their columns and their rules. For developers writing
migrations or queries. Every table also has a UUID `id`.

## Catalog

| Table | Columns | Rules |
|---|---|---|
| `accounts` | `name`, `platform`, `followers`, `created_at`, `updated_at`, `deleted_at` | Unique on `name` and `platform`. Soft delete |
| `resources` | `name`, `type`, `account_id`, `next_collection_at`, `collection_interval_days`, `last_collected_at`, `stall_notified_at`, timestamps, `deleted_at` | Unique on `name`, `account_id` and `type`. Soft delete |
| `releases` | `resource_id`, `version`, `released_at` | Dates are stored as the first of the month |
| `patra_cards` | `resource_id`, `card_uuid`, `version`, `card_updated_at`, `source_url`, `hub_resource_id`, `repository_resource_id`, details, `created_at` | Unique on `card_uuid`. One row per Patra card or datasheet |

Patra card details are `description`, `author`, `category`, `license`, `framework`, `model_type`,
`input_type`, `accuracy`, `keywords`, `is_gated`, `size`, `format`, `publication_year` and
`training_datasheet_uuid`. Several cards can point at one resource.

`hub_resource_id` and `repository_resource_id` link a card to the Hugging Face or GitHub resource it
names. They build the cross-registry links.

## Readings

| Table | Columns | Rules |
|---|---|---|
| `metrics` | `resource_id`, `reading`, `type`, `recorded_at` | One row per reading. Lifetime types hold one row per resource, updated in place |
| `metric_watermarks` | `resource_id`, `type`, `counted_through`, timestamps | Unique on `resource_id` and `type`. The last day added to a lifetime total |
| `metric_daily_totals` | `resource_id`, `type`, `day`, `reading`, timestamps | Unique on `resource_id`, `type` and `day`. Each day's closing lifetime total |

## Access and credentials

| Table | Columns | Rules |
|---|---|---|
| `vaults` | `account_id`, `name`, `expires_at`, timestamps | Unique on `name` and `account_id`. The name of a Tapis Vault secret, never its value |
| `admins` | `username`, `added_by`, timestamps, `deleted_at` | Unique on `username`. The root administrator is not stored here |
| `service_tokens` | `jti`, `resource_id`, `label`, `expires_at`, `revoked_at`, `created_at` | Unique on `jti`. Identifiers only, never the token |

## Operations

| Table | Columns | Rules |
|---|---|---|
| `job_failures` | `resource_id`, `account_id`, `job`, `subject`, `identifier`, `details`, `severity`, `failed_at` | One row per collection that used up its retries |

## Enumerations

| Enum | Values |
|---|---|
| `platform` | `github`, `ghcr`, `huggingface`, `npm`, `pypi`, `patra` |
| Resource `type` | `agent`, `container`, `dataset`, `model`, `package`, `repository`, `service` |
| `metric_type` | See [Metrics](metrics.md) |

## Migrations

Migrations live in `Sources/Insights/Migrations/` and run in the order `configure.swift` adds them.
Two more are added only in development: `ICICLESnapshotJuly2026` and `PatraCatalogAugust2026`. They
seed real accounts, resources and figures so a local dashboard has something to show.

#icicle-insights# #Reference# #Developer#
