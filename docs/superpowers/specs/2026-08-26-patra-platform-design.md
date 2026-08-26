# Patra as a collected platform

**Status:** Approved, not yet implemented
**Date:** 2026-08-26

Patra is ICICLE's own metadata registry for models, datasets, and eventually agents, managed under
the `icicleai` Tapis tenant. It is the institute's largest uncollected output. This adds `patra` as
a platform, `agent` as a resource type, and one collection job that discovers the catalog and
records how often each model has actually been run.

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

**One resource per model name, one per datasheet title. 29 resources. No releases.**

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

### Why no external identifier is stored

An earlier draft stored each card's uuid to make re-syncs idempotent. Grouping by name removes the
need: the dedup key is `(name, account_id, type)`, and `resources` already carries exactly that
unique constraint. The sync matches an existing resource by name and skips it.

This also removes what would have been the design's most awkward corner — a uuid column that was
meaningful for datasheets, meaningless for models (a name maps to up to 11 uuids), and needed a
partial unique index to survive soft deletes.

The cost is that card uuids are not persisted, so the collection job must fetch deployments in the
same pass that lists the cards. See [Collection](#collection).

## Data model

No schema changes. Three enum values.

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

**`PatraPlatform`** — all environments:

```
ALTER TYPE platform      ADD VALUE 'patra'
ALTER TYPE resource_type ADD VALUE 'agent'
ALTER TYPE metric_type   ADD VALUE 'deployments'
```

**`PatraCatalogAugust2026`** — `.development` only, registered beside `ICICLESnapshotJuly2026`.

PostgreSQL has historically refused to let a newly added enum value be *used* in the transaction
that added it. `MigrateLockedCommand` notes that each migration manages its own transactions
([MigrateLockedCommand.swift:38](../../../Sources/Insights/Commands/MigrateLockedCommand.swift)),
so no migration may both add `'patra'` and insert a row using it. Splitting costs nothing and is
correct whatever PostgreSQL 18 permits.

**The revert is one-way.** PostgreSQL has no `ALTER TYPE … DROP VALUE`. Removing `patra` would mean
rebuilding the type and rewriting `accounts.platform`, `resources.type` and `metric_watermarks.type`
— far too invasive for a revert path. `revert` is a no-op with a comment saying why.
`CollectionBackoff` sets this precedent for its cadence clamp.

### The seed

29 resources and 3 deployment readings, embedded as Swift literals to match
`ICICLESnapshotJuly2026`. A migration that reads files at runtime depends on the working directory
and on those files surviving into the container image.

`patra-modelcards.json` and `patra-datasets.json` move from the repository root into `data/` as the
provenance record, the way that snapshot cites its source export. The second is renamed to
`patra-datasheets.json` on the way, to match what the endpoint calls the record.

**Production is populated by the first sync**, not by a script or a migration. Bootstrap is one
manual step — an admin registers the `icicleai` account on platform `patra` — and the job creates
all 29 resources on its first run.

The account is `icicleai`, unhyphenated, while the existing accounts are `icicle-ai`. This is
correct: each registry is authoritative for its own spelling, a principle already recorded in the
snapshot's PyPI comment. `unique(name, platform)` keeps them distinct, and nothing groups by account
name.

## Collection

One job. `SyncPatraCatalog`, an `AsyncJob` taking an account id, dispatched by a new
`CollectPatraCatalog: AsyncScheduledJob` running daily.

Discovery and measurement are one pass because they must be: card uuids are not persisted, so the
only place that knows which uuids belong to `MegaDetector for Wildlife Detection` is the loop that
just listed them.

Not folded into `CollectAccountStats` for the reason that job gives for not folding into
`CollectDueResources`: the unit differs. Monthly is right for follower counts and too slow for a
live registry.

### Sequence

1. Page `/modelcards` until a short page returns. Group by `name`.
2. Page `/datasheets` the same way.
3. For each model card, page `/modelcard/{uuid}/deployments` and count.
4. Sum the counts per model name.
5. Create any resource whose name is not already registered.
6. Write one `deployments` reading per model resource.

Fetch everything, then write — the existing convention, and it matters more here than for the metric
collectors. A failure partway through a catalog write leaves half a registry.

### Rules

| Situation | Behaviour |
|---|---|
| Model name unseen | Create Resource (`type: .model`) |
| Datasheet title unseen | Create Resource (`type: .dataset`) |
| Name already registered | Skip creation, still record the reading |
| `is_private == true` | Skip the card entirely |
| Match is soft-deleted | Skip. An admin deleting a resource means "stop tracking this" |
| Card absent upstream | Keep the resource, log a warning. Deletion stays an admin action |
| Model with no deployments | Write a reading of 0 — the endpoint answered, and 0 is what it said |
| Datasheet resource | No reading at all. There is no datasheet deployments endpoint |

`version` is read only for grouping context and is not stored. `Yield Estimation` carries a null
`version` and a null `categories`; neither field reaching the database means neither can break it.

**The job creates; it does not update.** An existing resource is left as it is, even if the card's
name has changed upstream. Rewriting a resource name would orphan its metric history against a name
nobody recognises, and this design has no evidence about how often Patra names churn. Renames
surface as a new resource beside the old one — visible and correctable by an admin — rather than as
a silent mutation.

**Patra resources carry `nextCollectionAt = nil`** and are skipped by `dispatchSync`, exactly as
GHCR, npm and PyPI are. Their metrics arrive from this account-level job instead of the hourly
per-resource sweep. `add-a-resource.md` already documents a null due date as the correct state for a
platform the dispatcher does not route.

### Deployment counts

Summing across a name's cards is the honest resource-level figure: MegaDetector's 38 runs on
`6b-yolov9c` and 14 on `5a (OSA finetuning)` are 52 runs of MegaDetector.

Today's readings would be MegaDetector 52, ResNet50 16, MobileNetV2 1, and 0 for the other 20 model
resources.

This is an N+1 fetch by construction — one request per card, 37 today. At a daily cadence that is
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
this codebase that needs no credential, so the job carries a comment stating the omission is
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
| `SyncJobTests` | Happy path against a stubbed API, plus 422, decode failure, and vanished account |
| `SyncJobTests` | **Idempotency** — run the job twice, assert 29 resources both times, not 58 |
| `SyncJobTests` | **Pagination** — stub 60 cards, assert the loop pages past the 50 default |
| `SyncJobTests` | Grouping — 11 MegaDetector cards produce one resource whose reading is their sum |
| `SyncJobTests` | A soft-deleted resource is not resurrected; a private card is not registered |
| `labels.spec.ts` | The new platform, resource type, and metric type |

`stubAPI` matches paths exactly, so assert the URLs the job builds including `skip` and `limit`.
The pagination and grouping tests are the two that justify this design; without them both defects
ship green.

## Documentation

Ship with the change, per CLAUDE.md.

`collection-schedule.md` (Patra's metric, cadence, job name), `data-model.md` (the card-to-resource
mapping and why versions are not stored), `add-a-resource.md` (kind list), `glossary.md` (Patra,
datasheet, deployment), `register-an-account.md`, `admin-console.md`, and the index in
`docs/README.md`.

`add-a-collector.md` needs a note that Patra is the first credential-free collector, and the first
whose job is account-level and therefore does not call `recordSuccessfulCollection`.

`TODO.md` records the `agent` gap.

## Out of scope, found on the way

Recorded because they are real, not because this change addresses them.

- **Card versions are not stored anywhere.** MegaDetector's 11 variants become one resource with one
  summed count, and the fact that there were 11 is not recorded. This is the deliberate cost of
  keeping `Release` meaning an ICICLE software release.
- **Agents have no endpoint.** `ResourceType.agent` lands so agents can be registered by hand and so
  the dashboard knows the type, but nothing in the API publishes them. `/agent-tools/*` are AI
  tooling routes, not agent records. The job grows a third endpoint when Patra ships one.
- **Per-deployment quality metrics are not collected.** `precision`, `recall`, `f1_score`, `map_50`
  and `map_50_95` describe model quality, not project impact, and Insights has no shape for them.
- **`author` is deliberately not stored.** The field conflates uploader with origin — `Google
  DeepMind` is listed as an author — includes a `Demo Author` test account, and splits real people
  across handles: `habg21` and `Harikesh Byrandurga Gopinath` both publish Unet++ variants, as do
  `swathivm` and `Swathi V` on Yolo. The export shows 18 authors where the truth is nearer 12, so
  any count over the column would be quietly wrong.
- **Upstream holds name variants that grouping cannot fix.** `Yolo Object Detecion - for detecting a
  soft toy` and `Yolo_Object_Detecion__SoftToy` are the same model under two names, and will become
  two resources. That is Patra's data, not this mapping.
- **`/experiments/{domain}/…` is unexplored.** It may hold a richer usage signal than deployment
  counts, but it is keyed by domain and user rather than by model card, so it does not fit the
  resource model without further design.
