# Patra as a collected platform

**Status:** Approved, not yet implemented
**Date:** 2026-08-26

Patra is ICICLE's own metadata registry for models, datasets, and eventually agents, managed under
the `icicleai` Tapis tenant. It is the institute's largest uncollected output. This adds `patra` as
a platform, `agent` as a resource type, a `patra_cards` table recording the registry's own
identifiers, and two collection jobs — one that discovers the catalog and one that records how often
each model has actually been run.

## What the API actually provides

Verified against `https://patrabackend.pods.icicleai.tapis.io` on 2026-08-26. It is a FastAPI
service publishing OpenAPI 3.1 at `/openapi.json`.

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

The `q` parameter was not exercised; the pod stopped before it could be tested. Nothing in this
design depends on it.

## What a Patra card maps to

A Patra model card is a *(name, version)* pair with its own uuid, not a distinct model. The catalog
is far smaller than its card count suggests.

| | Cards | Distinct |
|---|---|---|
| Model cards | 37 | **23** names |
| Datasheets | 6 | 6 titles |

`MegaDetector for Wildlife Detection` alone is 11 cards — versions `5a`, `5b`, `5c`, `5-optimized`,
`5a_ena`, `6b-yolov9c` and four finetuning variants — published by four different authors.

**One resource per model name, one per datasheet title — 29 resources — with all 43 cards recorded
in `patra_cards`.**

### Why the sync creates no releases

`Release` means an ICICLE software release. The dashboard has a whole `features/releases/` area and
an admin release-management screen built around that meaning.

Mapping card versions onto it would have produced 37 release rows carrying values like
`yolo11l_ep1_bs32_lr0.005_8aa95a86.pt` and `6b-yolov9c (OSA finetuning 20 epochs)`. The parser in
[release-version.ts](../../../Dashboard/src/app/features/releases/release-version.ts) would not
break on these — it classifies unrecognised values as `label` by design — which is precisely the
problem. They would be accepted silently and bury ICICLE's real releases under model checkpoint
filenames.

Releases stay manual. An administrator may still cut a release against a Patra model resource
through the existing screen, and some will. The sync never writes one.

`patra_cards` is what `Release` would have been for this data, in a table of its own. It carries the
version, so nothing is lost, and it is invisible to every releases surface.

### Why identity is the uuid, not the name

The alternative was matching each card's `name` against `resources.name`. That works, but it makes a
field Patra controls the only thing tying a card to a resource — a rename silently produces a
duplicate resource, and there is no way to tell that from a genuine new model.

`card_uuid` is stable by construction and unique across the registry. Nothing else is: name is not
unique, `(author, name)` collides for 7 pairs, and `(author, name, version)` still collides once —
`anagha27 / beans-disease-classifier / 1.0` exists twice under two uuids, so 37 cards yield 36
distinct triples.

A uuid column on `resources` could not work, because a model name maps to up to 11 uuids. A child
table is the shape the data actually has.

## Data model

**`patra_cards`** — one row per Patra card, child of `resources`:

| Column | Notes |
|---|---|
| `id` | |
| `resource_id` | → `resources(id)` `ON DELETE CASCADE` |
| `card_uuid` | `UNIQUE`. The registry's own identifier |
| `version` | Nullable — `Yield Estimation` has none |
| `card_updated_at` | Nullable. The card's `updated_at`, stored as given |
| `created_at` | |

Datasheets get a row too, with a null `version`. That is what gives datasheet resources exact
matching rather than title-equality.

**Soft deletes need no special handling.** A soft-deleted resource keeps its card rows, so the sync
matches the uuid, follows it to a resource with `deleted_at` set, and skips. No partial unique index.

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

## Migrations

Two, and the split is load-bearing.

**`PatraPlatform`** — all environments. Adds the three enum values and creates `patra_cards`. Safe
together: the new table references no enum, so nothing here *uses* a value added in the same
transaction.

```
ALTER TYPE platform      ADD VALUE 'patra'
ALTER TYPE resource_type ADD VALUE 'agent'
ALTER TYPE metric_type   ADD VALUE 'deployments'
CREATE TABLE patra_cards …
```

**`PatraCatalogAugust2026`** — `.development` only, registered beside `ICICLESnapshotJuly2026`.

PostgreSQL has historically refused to let a newly added enum value be *used* in the transaction
that added it. `MigrateLockedCommand` notes that each migration manages its own transactions
([MigrateLockedCommand.swift:38](../../../Sources/Insights/Commands/MigrateLockedCommand.swift)),
so no migration may both add `'patra'` and insert a row using it. Splitting costs nothing and is
correct whatever PostgreSQL 18 permits.

**The revert is partly one-way.** It drops `patra_cards`, which is clean. It cannot remove the enum
values — PostgreSQL has no `ALTER TYPE … DROP VALUE`, and rebuilding the type would mean rewriting
`accounts.platform`, `resources.type` and `metric_watermarks.type`. The values are left behind with
a comment saying why. `CollectionBackoff` sets this precedent for its cadence clamp.

### The seed

29 resources, 43 cards, and 3 deployment readings, embedded as Swift literals to match
`ICICLESnapshotJuly2026`. A migration that reads files at runtime depends on the working directory
and on those files surviving into the container image.

`patra-modelcards.json` and `patra-datasets.json` move from the repository root into `data/` as the
provenance record, the way that snapshot cites its source export. The second is renamed to
`patra-datasheets.json` on the way, to match what the endpoint calls the record.

**The seed must carry the real card uuids.** A development database seeded with invented ones, plus
one sync, re-registers all 43 cards.

**Production is populated by the first sync**, not by a script or a migration. Bootstrap is one
manual step — an admin registers the `icicleai` account on platform `patra` — and the catalog job
creates all 29 resources and 43 cards on its first run.

The account is `icicleai`, unhyphenated, while the existing accounts are `icicle-ai`. This is
correct: each registry is authoritative for its own spelling, a principle already recorded in the
snapshot's PyPI comment. `unique(name, platform)` keeps them distinct, and nothing groups by account
name.

## Collection

Two jobs, because discovery and measurement are different units.

| Job | Level | Trigger | Writes |
|---|---|---|---|
| `SyncPatraCatalog` | account | new daily scheduled job | Resources, PatraCards |
| `SyncPatraDeployments` | resource | existing hourly sweep, via `dispatchSync` | one `deployments` Metric |

### `SyncPatraCatalog`

Payload is an account id. Dispatched by `CollectPatraCatalog`, a new `AsyncScheduledJob` running
daily. Not folded into `CollectAccountStats` for the reason that job gives for not folding into
`CollectDueResources`: the unit differs. Monthly is right for follower counts and too slow for a
live registry.

Pages `/modelcards` and `/datasheets`, groups model cards by name, then:

| Situation | Behaviour |
|---|---|
| `card_uuid` already in `patra_cards` | Skip. This is the idempotency guarantee |
| Model name unseen | Create Resource (`type: .model`), then its card row |
| Model name known | Attach the card row to the existing Resource |
| Datasheet title unseen | Create Resource (`type: .dataset`), then its card row |
| `is_private == true` | Skip the card entirely |
| Card's resource is soft-deleted | Skip. An admin deleting a resource means "stop tracking this" |
| Card absent upstream | Keep both rows, log a warning. Deletion stays an admin action |
| Known uuid, changed name | Keep the existing attachment, log the rename for an admin |

`version` may be null and is stored as null. `Yield Estimation` carries a null `version` and a null
`categories`; the latter is never read.

**Renames are logged, never applied.** A resource groups up to 11 cards, so renaming it because one
of them changed would be wrong, and rewriting a resource name orphans its metric history against a
name nobody recognises. Recording the uuid is what makes the rename *visible* — which was the whole
argument for this table over name matching.

New resources get `nextCollectionAt` set to now so the next sweep measures them.

**It does not call `recordSuccessfulCollection`.** That is a deliberate break from the convention in
[add-a-collector.md](../../how-to/add-a-collector.md) and needs a comment saying so. The method
anchors metric cadence and backoff per resource; this job is account-level and writes no metrics.

Fetch everything, then write — the existing convention, and it matters more here than for the metric
collectors. A failure partway through a catalog write leaves half a registry.

### `SyncPatraDeployments`

Routes through `dispatchSync` like every other per-resource collector, so it inherits the capped
backoff, the failure classification, and the retention guard rather than reimplementing them. This
is possible only because `patra_cards` lets a resource answer which uuids are its own.

It reads its resource's card rows, pages `/modelcard/{uuid}/deployments` for each, sums the counts,
and writes one `deployments` reading. Summing is the honest resource-level figure: MegaDetector's 38
runs on `6b-yolov9c` and 14 on `5a (OSA finetuning)` are 52 runs of MegaDetector.

A `.dataset` resource has no deployments endpoint. The job records the collection as successful and
writes no reading.

Today's readings would be MegaDetector 52, ResNet50 16, MobileNetV2 1, and 0 for the other 20 model
resources. A model with no deployments records 0 rather than nothing: the endpoint answered, and 0
is what it said.

This is an N+1 fetch by construction — one request per card. At 37 cards on a weekly cadence that is
negligible, and there is no bulk endpoint.

### Pagination is mandatory

`limit` defaults to **50** and rejects anything above 100 with a 422. Every loop must page on `skip`
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

**`patra_cards` is not exposed through the API or the dashboard.** It is collection bookkeeping.
Surfacing card versions is a later change with its own design, not a side effect of this one.

**`deployments` needs no `METRIC_LABELS` entry.** That map exists only for metrics whose bare name
overstates their window. A deployment count is a lifetime total and its name is honest.

**No new empty-state work.** GHCR, npm and PyPI resources already carry no metrics, so the
components handle metric-less resources today.

## Testing

| Suite | Adds |
|---|---|
| `SyncJobTests` | Both jobs against a stubbed API: happy path, 422, decode failure, vanished subject |
| `SyncJobTests` | **Idempotency** — run the catalog job twice, assert 29 resources and 43 cards both times |
| `SyncJobTests` | **Pagination** — stub 60 cards, assert the loop pages past the 50 default |
| `SyncJobTests` | Grouping — 11 MegaDetector cards produce one resource with 11 card rows |
| `SyncJobTests` | Deployments sum across a resource's cards; a `.dataset` resource writes no reading |
| `SyncJobTests` | Null `version` stored as null; private card skipped; soft-deleted resource not resurrected |
| `SyncJobTests` | A known uuid arriving under a new name logs and does not rename or duplicate |
| `QueueSweepTests` | `patra` routes to `SyncPatraDeployments` and re-books correctly |
| `labels.spec.ts` | The new platform, resource type, and metric type |

`stubAPI` matches paths exactly, so assert the URLs the jobs build including `skip` and `limit`.
Pagination, grouping and the rename case are the three that justify this design; without them the
defects ship green.

## Documentation

Ship with the change, per CLAUDE.md.

`collection-schedule.md` (Patra's metric, cadence, job names), `data-model.md` (`patra_cards`, the
card-to-resource mapping), `add-a-resource.md` (kind list), `glossary.md` (Patra, datasheet,
deployment, card), `register-an-account.md`, `admin-console.md`, and the index in `docs/README.md`.

`add-a-collector.md` needs a note that Patra is the first credential-free collector, and that its
catalog half is account-level and therefore does not call `recordSuccessfulCollection`.

`TODO.md` records the `agent` gap.

## Out of scope, found on the way

Recorded because they are real, not because this change addresses them.

- **Card versions are stored but not shown.** `patra_cards.version` holds all 43, and nothing
  renders them. Surfacing "this model has 11 variants" is a dashboard change with its own design.
- **Agents have no endpoint.** `ResourceType.agent` lands so agents can be registered by hand and so
  the dashboard knows the type, but nothing in the API publishes them. `/agent-tools/*` are AI
  tooling routes, not agent records. The catalog job grows a third endpoint when Patra ships one.
- **Per-deployment quality metrics are not collected.** `precision`, `recall`, `f1_score`, `map_50`
  and `map_50_95` describe model quality, not project impact, and Insights has no shape for them.
- **`author` is deliberately not stored.** The field conflates uploader with origin — `Google
  DeepMind` is listed as an author — includes a `Demo Author` test account, and splits real people
  across handles: `habg21` and `Harikesh Byrandurga Gopinath` both publish Unet++ variants, as do
  `swathivm` and `Swathi V` on Yolo. The export shows 18 authors where the truth is nearer 12, so
  any count over the column would be quietly wrong. `patra_cards` is where it would go if that
  changes.
- **Upstream holds name variants that grouping cannot fix.** `Yolo Object Detecion - for detecting a
  soft toy` and `Yolo_Object_Detecion__SoftToy` are the same model under two names, and will become
  two resources. That is Patra's data, not this mapping.
- **`/experiments/{domain}/…` is unexplored.** It may hold a richer usage signal than deployment
  counts, but it is keyed by domain and user rather than by model card, so it does not fit the
  resource model without further design.
