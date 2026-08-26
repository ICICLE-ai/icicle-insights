# Patra as a collected platform

**Status:** Approved, not yet implemented
**Date:** 2026-08-26

Patra is ICICLE's own metadata registry for models, datasets, and eventually agents, managed under
the `icicleai` Tapis tenant. It is the institute's largest uncollected output. This adds `patra` as
a platform, `agent` as a resource type, and two collection jobs: one that discovers the catalog and
one that records how often each model has actually been run.

## What the API actually provides

Verified against `https://patrabackend.pods.icicleai.tapis.io` on 2026-08-26, not inferred from the
exports. It is a FastAPI service publishing OpenAPI 3.1 at `/openapi.json`.

| Endpoint | Returns | Query |
|---|---|---|
| `GET /modelcards` | `ModelCardSummary[]` | `q`, `skip`, `limit` |
| `GET /datasheets` | `DatasheetSummary[]` | `q`, `skip`, `limit` |
| `GET /modelcard/{uuid}/deployments` | `ModelDeployment[]` | `skip`, `limit` |

The dataset endpoint is `/datasheets`, not `/datasets`. Patra calls a dataset record a datasheet.

```
ModelCardSummary   uuid*, name*, categories, author, version, short_description,
                   is_gated, is_private, updated_at
DatasheetSummary   uuid*, title*, creator, category, is_private, updated_at
ModelDeployment    experiment_id*, device_id*, status*, timestamp,
                   precision, recall, f1_score, map_50, map_50_95
```

Today the catalog holds **37 model cards, 6 datasheets, and 69 deployment records**.

**Unauthenticated callers see only public records.** The OpenAPI description states this directly:
"JWT bearer shows private; unauthenticated shows only public." Collecting anonymously is therefore a
safety property of this design, not a convenience — see [No credential path](#no-credential-path).

## The identity problem

A Patra model card is a *(name, version)* pair with its own uuid, not a distinct model. The catalog
is far smaller than its card count suggests.

| | Cards | Distinct |
|---|---|---|
| Model cards | 37 | **23** names |
| Datasheets | 6 | 6 titles |

`MegaDetector for Wildlife Detection` alone is 11 cards — versions `5a`, `5b`, `5c`, `5-optimized`,
`5a_ena`, `6b-yolov9c` and four finetuning variants — published by four different authors.

Registering one resource per card would list MegaDetector eleven times in every chart and table.
Registering one per name loses the versions. The schema already has the right shape for this:

**A model name becomes a `Resource`; a card becomes a `Release` under it.**

That yields **29 resources (23 models + 6 datasheets) carrying 37 releases**, and
`unique(name, account_id, type)` enforces it without further work.

### Why `external_id` is required

Nothing in the card payload is stable enough to match on across syncs. Name is not unique.
`(author, name)` is not unique — 7 pairs collide. `(author, name, version)` is not unique either:
`anagha27 / beans-disease-classifier / 1.0` exists twice under two uuids, so 37 cards yield only 36
distinct triples.

Only `uuid` is unique, by construction. Without storing it, the second sync matches nothing and
inserts all 37 cards again. `releases` has no unique constraint today, so nothing would stop it.

The uuid identifies a **card**, so it lives on whichever row is one-to-one with a card. This is
asymmetric between the two kinds, and correctly so:

| Patra record | Becomes | Holds the uuid |
|---|---|---|
| Model card | a `Release` under a Resource named for the model | `Release.externalID` |
| Datasheet | a `Resource` with no releases | `Resource.externalID` |

A model `Resource` such as `MegaDetector for Wildlife Detection` is not a Patra entity at all — it
is a name eleven cards share — so it correctly carries no uuid. A datasheet `Resource` *is* a card,
so it does. Datasheets have no `version` field, and `releases.version` is `.required`, so they
cannot be modelled as releases without inventing data.

## Data model

**`Platform.patra`**, appended to the enum rather than inserted alphabetically. The existing order
(`github, ghcr, huggingface, npm, pypi`) is already curated rather than sorted, and
[composition-chart.ts:125](../../../Dashboard/src/app/features/dashboard/charts/composition-chart.ts)
colours platforms by their index in `PLATFORM_ORDER`. Inserting mid-array silently recolours PyPI.

```swift
var maxCollectionIntervalDays: Int { case .patra: 30 }
var retentionWindowDays: Int? { case .patra: nil }
```

Deployment records do not age out of a window, so Patra cannot lose data to a late sweep. Its cap is
about series density, exactly as Hugging Face's is.

**`ResourceType.agent`**, inserted alphabetically to match that enum's existing ordering.
`resourceTypeColor` has no consumers, so `RESOURCE_TYPE_ORDER` only drives the admin form's dropdown
and the shift is harmless.

**`MetricType.deployments`**, with `allTime` returning `nil`. The existing doc comment on that
property already describes this case exactly — "the series itself is the total and keeping it lets
the figure fall as well as rise." A deployment count is read whole on every sweep, so there is no
rolling window, no watermark, and no all-time twin. It belongs with `forks`, `likes`, `stars`, and
`subscribers`.

**`externalID: String?`** on both `Resource` and `Release`. Nullable, so every existing GitHub,
GHCR, Hugging Face, npm and PyPI row is untouched. Stored as the bare uuid; if a second platform
ever needs the field and its identifiers are not globally unique, namespace at write time
(`patra:<uuid>`) rather than weakening the index.

## Migrations

Two, and the split is load-bearing.

**`PatraPlatform`** — all environments:

```
ALTER TYPE platform      ADD VALUE 'patra'
ALTER TYPE resource_type ADD VALUE 'agent'
ALTER TYPE metric_type   ADD VALUE 'deployments'
resources + external_id (string, nullable)
releases  + external_id (string, nullable)
```

**`PatraCatalogAugust2026`** — `.development` only, registered beside `ICICLESnapshotJuly2026`.

PostgreSQL has historically refused to let a newly added enum value be *used* in the transaction
that added it. `MigrateLockedCommand` notes that each migration manages its own transactions
([MigrateLockedCommand.swift:38](../../../Sources/Insights/Commands/MigrateLockedCommand.swift)),
so no migration may both add `'patra'` and insert a row using it. Splitting costs nothing and is
correct whatever PostgreSQL 18 permits. Adding *columns* alongside the enum values is safe, since
nothing there uses them.

**The revert is one-way.** PostgreSQL has no `ALTER TYPE … DROP VALUE`. Removing `patra` would mean
rebuilding the type and rewriting `accounts.platform`, `resources.type` and `metric_watermarks.type`
— far too invasive for a revert path. `revert` drops the columns and indexes and leaves the enum
values, with a comment saying why. `CollectionBackoff` sets this precedent for its cadence clamp.

### Unique indexes differ per table

| Table | Index | Why |
|---|---|---|
| `releases` | `UNIQUE (external_id)` | No soft deletes on this table |
| `resources` | `UNIQUE (external_id) WHERE deleted_at IS NULL` | Soft-deleted rows keep their uuid |

Without the partial predicate, deleting a Patra resource in the console makes every subsequent sync
fail on the constraint when it tries to re-insert that uuid.

### The seed

Embedded as Swift literals, matching `ICICLESnapshotJuly2026`. A migration that reads files at
runtime depends on the working directory and on those files surviving into the container image.

`patra-modelcards.json` and `patra-datasets.json` move from the repository root into `data/` as the
provenance record, the way that snapshot cites its source export. The second is renamed to
`patra-datasheets.json` on the way, to match what the endpoint actually calls the record.

**The seed must carry the uuids.** A development database seeded without them, plus one sync, is the
same doubling trap from the other direction.

**Production is populated by the first sync**, not by a script or a migration. Bootstrap is one
manual step — an admin registers the `icicleai` account on platform `patra` — and the catalog job
creates all 29 resources and 37 releases on its first run.

The account is `icicleai`, unhyphenated, while the existing accounts are `icicle-ai`. This is
correct: each registry is authoritative for its own spelling, a principle already recorded in the
snapshot's PyPI comment. `unique(name, platform)` keeps them distinct, and nothing groups by account
name.

## Collection

Two jobs, because discovery and measurement are different units.

| Job | Level | Trigger | Writes |
|---|---|---|---|
| `SyncPatraCatalog` | account | new daily scheduled job | Resources, Releases |
| `SyncPatraDeployments` | resource | existing hourly sweep, via `dispatchSync` | one `deployments` Metric |

### `SyncPatraCatalog`

Payload is an account id, not a resource id. Dispatched by `CollectPatraCatalog`, a new
`AsyncScheduledJob` running daily. Not folded into `CollectAccountStats` for the reason that job
gives for not folding into `CollectDueResources`: the unit differs. Monthly is right for follower
counts and too slow for a live registry.

Upsert rules, in order:

| Situation | Behaviour |
|---|---|
| Model card, name unseen | Create Resource (`type: .model`), then Release keyed by uuid |
| Model card, name known | Attach Release to the existing Resource |
| Release uuid already present | Skip — this is the idempotency guarantee |
| Datasheet | Resource keyed by uuid (`type: .dataset`), no release |
| `version` is null | Create the Resource, skip the Release. Never invent a version |
| `is_private == true` | Skip the card entirely |
| Match is soft-deleted | Skip. An admin deleting a resource means "stop tracking this" |
| Card absent upstream | Keep it, log a warning. Deletion stays an admin action |

`Yield Estimation` is the live null-version case; its `categories` is null too.

**The job creates; it does not update.** An existing resource or release matched by uuid is left
exactly as it is, even if the card's name or `updated_at` has changed upstream. Rewriting a resource
name would orphan its metric history against a name nobody recognises, and this design has no
evidence about how often Patra names churn. Renames therefore surface as a new resource alongside
the old one, which is visible and correctable by an admin, rather than as a silent mutation.
Revisit once there is real evidence of churn.

**It does not call `recordSuccessfulCollection`.** That is a deliberate break from the convention in
[add-a-collector.md](../../how-to/add-a-collector.md) and needs a comment saying so. The method
anchors metric cadence and backoff per resource; this job is account-level and writes no metrics.
New resources get `nextCollectionAt` set to now so the next sweep measures them.

### `SyncPatraDeployments`

Routes through `dispatchSync` like every other per-resource collector, so it inherits the capped
backoff, the failure classification, and the retention guard rather than reimplementing them.

It reads its resource's releases, fetches `/modelcard/{uuid}/deployments` for each `externalID`,
sums the counts, and writes one `deployments` reading. Summing is the honest resource-level figure:
MegaDetector's 38 runs on `6b-yolov9c` and 14 on `5a (OSA finetuning)` are 52 runs of MegaDetector.

Datasheet resources have no releases and no deployments endpoint. They record a reading of 0 rather
than being skipped, so the series stays continuous.

Today's readings would be MegaDetector 52, ResNet50 16, MobileNetV2 1, and 0 for the other 26.

This is an N+1 fetch by construction — one request per release. At 37 releases on a weekly cadence
that is negligible, and there is no bulk endpoint.

### Pagination is mandatory in both jobs

`limit` defaults to **50** and rejects anything above 100 with a 422. Both loops must page on `skip`
until a short page returns.

This is the defect most likely to ship working and break silently later:

- `/modelcards` returns 37 today. A non-paginating collector works until the 51st card is published.
- `/modelcard/{uuid}/deployments` returns 38 for MegaDetector `6b-yolov9c` — already 76% of the
  default page.

### No credential path

No `Vault` lookup, no `SecretProvider`, no `JobError.missingToken`. Patra is the first collector in
this codebase that needs no credential, so both jobs carry a comment stating the omission is
deliberate.

Authenticating would be actively harmful: a JWT-bearing caller sees private records, and this
dashboard is public. Anonymous collection is what guarantees Insights cannot publish the name of a
private card. The `is_private` skip rule is defence in depth behind that.

## Dashboard

| File | Change |
|---|---|
| `core/api/models.ts` | `Platform` += `patra`, `ResourceType` += `agent`, `MetricType` += `deployments` |
| `shared/format/labels.ts` | `PLATFORM_LABELS`, `PLATFORM_ORDER`, `PLATFORM_GROUPS`, `RESOURCE_TYPE_ORDER` |
| `styles.css` | `--ins-platform-patra`, light and dark |
| `shared/charts/chart-palette.ts` | `FALLBACK.platforms.patra` |
| `shared/format/labels.spec.ts` | Cover the new members |

**Patra joins the existing `models` group.** That group is already labelled "Models & Datasets"
because Hugging Face spans both, so Patra extends the pattern rather than breaking it. The picker
renders "Hugging Face + Patra", and `spansMultipleRegistries` already handles multi-registry groups
— it was written for npm + pypi. The comment in `labels.ts` explaining why the group cannot be split
stays true and gains Patra as a second example.

**`deployments` needs no `METRIC_LABELS` entry.** That map exists only for metrics whose bare name
overstates their window. A deployment count is a lifetime total and its name is honest.

**No new empty-state work.** GHCR, npm and PyPI resources already carry no metrics, so the
components handle metric-less resources today.

## Testing

| Suite | Adds |
|---|---|
| `SyncJobTests` | Both jobs against a stubbed API: happy path, 422, decode failure, vanished resource |
| `SyncJobTests` | **Idempotency** — run the catalog job twice, assert 29 resources and 37 releases, not 58 and 74 |
| `SyncJobTests` | **Pagination** — stub 60 cards, assert the loop pages past the 50 default |
| `SyncJobTests` | Null `version` skips the release; soft-deleted resource is not resurrected |
| `QueueSweepTests` | `patra` routes to `SyncPatraDeployments` and re-books correctly |
| `labels.spec.ts` | The new platform, resource type, and metric type |

`stubAPI` matches paths exactly, so assert the URLs the jobs build including `skip` and `limit`.
The pagination and idempotency tests are the two that justify this design; without them both
defects ship green.

## Documentation

Ship with the change, per CLAUDE.md.

`collection-schedule.md` (Patra's metrics, cadence cap, job names), `data-model.md` (`external_id`,
the card-to-release mapping), `add-a-resource.md` (cadence table, kind list), `glossary.md`
(Patra, datasheet, deployment), `register-an-account.md`, `admin-console.md`, and the index in
`docs/README.md`.

`add-a-collector.md` needs a note that Patra is the first credential-free collector and the first
whose catalog half deliberately does not call `recordSuccessfulCollection`.

`TODO.md` records the `agent` gap.

## Out of scope, found on the way

Recorded because they are real, not because this change addresses them.

- **Agents have no endpoint.** `ResourceType.agent` lands so agents can be registered by hand and so
  the dashboard knows the type, but nothing in the API publishes them. `/agent-tools/*` are AI
  tooling routes, not agent records. The catalog job grows a third endpoint when Patra ships one.
- **Per-deployment quality metrics are not collected.** `precision`, `recall`, `f1_score`, `map_50`
  and `map_50_95` describe model quality, not project impact, and Insights has no shape for them.
- **`author` is deliberately not stored.** The field conflates uploader with origin — `Google
  DeepMind` is listed as an author — includes a `Demo Author` test account, and splits real people
  across handles: `habg21` and `Harikesh Byrandurga Gopinath` both publish Unet++ variants, as do
  `swathivm` and `Swathi V` on Yolo. The export shows 18 authors where the truth is nearer 12, so
  any count over the column would be quietly wrong. Adding it later costs one migration and one
  re-sync, because the sync is idempotent.
- **`updated_at` is stored as `Release.releasedAt`.** It means "last modified", not "published", and
  is the only date Patra offers. Needs a comment so nobody reads those dates as release dates.
- **Upstream holds name variants that grouping cannot fix.** `Yolo Object Detecion - for detecting a
  soft toy` and `Yolo_Object_Detecion__SoftToy` are the same model under two names at the same
  version, and will become two resources. That is Patra's data, not this mapping.
- **`/experiments/{domain}/…` is unexplored.** It may hold a richer usage signal than deployment
  counts, but it is keyed by domain and user rather than by model card, so it does not fit the
  resource model without further design.
