# Patra Platform — Implementation Plan

**Spec:** [docs/superpowers/specs/2026-08-26-patra-platform-design.md](docs/superpowers/specs/2026-08-26-patra-platform-design.md) (committed, `a0b0325`)

> **For agentic workers:** use `superpowers:subagent-driven-development` or
> `superpowers:executing-plans`. Steps use `- [ ]` for tracking.
> Copy this plan to `docs/superpowers/plans/2026-08-26-patra-platform.md` as the first action, so it
> travels with the repository.

## Context

Patra is ICICLE's own metadata registry for models and datasets, managed under the `icicleai` Tapis
tenant, and the institute's largest uncollected output. Insights currently knows nothing about it.

This adds `patra` as a platform, `agent` as a resource type, a `patra_cards` table, two collection
jobs, and a graph showing where an artifact exists across registries.

Three findings from reading the live API shaped the design and are why this is not a trivial enum
addition:

1. **Patra cards are `(name, version)` pairs, not models.** 37 cards are 23 models — `MegaDetector
   for Wildlife Detection` alone is 11 cards. One resource per *name*; cards recorded in
   `patra_cards`. Releases are untouched: they mean ICICLE software releases, and filling them with
   `yolo11l_ep1_bs32_lr0.005_8aa95a86.pt` would bury real release history.
2. **Patra reports genuine usage.** `/modelcard/{uuid}/deployments` holds 69 completed runs on real
   hardware. That is what makes Patra chartable rather than a list of names.
3. **Patra imports from other registries.** 3 of its 6 datasheets are already tracked here as
   Hugging Face datasets. Provenance links record that.

## Verified against the live API (2026-08-26)

The pod has since stopped; these were captured while it was up.

| Fact | Value |
|---|---|
| Base URL | `https://patrabackend.pods.icicleai.tapis.io` |
| List endpoints | `/modelcards`, **`/datasheets`** (not `/datasets`) |
| Pagination | `skip`, `limit` — **default 50, max 100**, 422 above |
| Catalog size | 37 model cards, 6 datasheets, 69 deployments |
| Auth | Unauthenticated returns public records only |
| Detail | `ModelCardDetail.ai_model` → `AIModel.location`; `training_datasheet_uuid` |
| Timestamps | `2026-07-30T16:38:28.157335+00:00` — fractional seconds + offset |

## Global Constraints

- **`withInsightsApp` must not be renamed.** `VaporTesting`'s generic `withApp` wins overload
  resolution for single-expression closures and hands the test an empty app.
- **Collect anonymously.** No `Vault`, no `SecretProvider`. A JWT-bearing caller sees private
  records and this dashboard is public. Both jobs carry a comment saying the omission is deliberate.
- **Fetch everything, then write.** A failure partway through a catalog write leaves half a registry.
- **`swift-format` is authoritative** — `just fmt` before every commit.
- **Comments explain why**, not what. Record rejected alternatives and non-obvious failure modes.
- **Ship docs with the change** (Task 12), per CLAUDE.md.
- **`just build` is currently broken** in this worktree — the `docker-entrypoint.sh` build-context
  fix is uncommitted in the main checkout. Needed only for container verification.

## File structure

**Create**

| File | Responsibility |
|---|---|
| `Sources/Insights/Models/PatraCard.swift` | `PatraCard` model |
| `Sources/Insights/Migrations/PatraPlatform.swift` | Enum values + `patra_cards` |
| `Sources/Insights/Migrations/PatraCatalogAugust2026.swift` | Dev seed |
| `Sources/Insights/Services/Patra/PatraAPI.swift` | Wire types, paging, date parsing |
| `Sources/Insights/Queues/Collectors/SyncPatraCatalog.swift` | Discovery + provenance |
| `Sources/Insights/Queues/Collectors/SyncPatraDeployments.swift` | Deployment counts |
| `Sources/Insights/Queues/Scheduled/CollectPatraCatalog.swift` | Daily dispatcher |
| `Dashboard/src/app/features/dashboard/charts/provenance-graph.ts` | The graph |

**Modify:** `Models/Account.swift`, `Models/Resource.swift`, `Models/Metric.swift`,
`DTOs/ResourceDTO.swift`, `Queues/Collectors/SyncDispatch.swift`, `configure.swift`,
`Tests/InsightsTests/TestSupport.swift`, `SyncJobTests.swift`, `QueueSweepTests.swift`,
`Dashboard/src/app/core/api/models.ts`, `shared/format/labels.ts`, `shared/charts/chart-palette.ts`,
`Dashboard/src/styles.css`.

`Services/Patra/` mirrors `Services/Tapis/` — platform specifics stay behind one directory.

---

## Phase 1 — Schema

### Task 1: Enum values and `patra_cards`

**Files:** create `Models/PatraCard.swift`, `Migrations/PatraPlatform.swift`; modify
`Models/Account.swift`, `Models/Resource.swift`, `Models/Metric.swift`, `configure.swift`.

**Produces:** `Platform.patra`, `ResourceType.agent`, `MetricType.deployments`, `PatraCard`.

- [ ] **1.1** Add `patra` to `Platform` — **appended**, not alphabetical. `composition-chart.ts:125`
  colours by `PLATFORM_ORDER.indexOf`, so inserting mid-array recolours PyPI. Add
  `case .patra: 30` to `maxCollectionIntervalDays` and `case .patra: nil` to `retentionWindowDays`.
- [ ] **1.2** Add `agent` to `ResourceType`, first (that enum is alphabetical).
- [ ] **1.3** Add `deployments` to `MetricType`. In `allTime`, it returns `nil` — put it on the
  `case .forks, .likes, .stars, .subscribers: nil` line. A count is read whole each sweep, so there
  is no window, no watermark, no all-time twin.
- [ ] **1.4** Write `PatraCard`, following `Release.swift` for shape:

```swift
/// One Patra card — a (name, version) record with the registry's own uuid.
///
/// Not a `Release`: that means an ICICLE software release, and card versions are values like
/// `yolo11l_ep1_bs32_lr0.005_8aa95a86.pt` that would bury real release history.
final class PatraCard: Model, @unchecked Sendable {
  static let schema = "patra_cards"

  @ID(key: .id) var id: UUID?
  @Parent(key: "resource_id") var resource: Resource
  /// Patra's own identifier. The only stable key — name is not unique, and neither is
  /// (author, name, version): one pair exists twice under two uuids.
  @Field(key: "card_uuid") var cardUUID: String
  @OptionalField(key: "version") var version: String?
  @OptionalField(key: "card_updated_at") var cardUpdatedAt: Date?
  /// Patra's `AIModel.location`, stored raw so a failed resolution is auditable.
  @OptionalField(key: "source_url") var sourceURL: String?
  @OptionalParent(key: "hub_resource_id") var hubResource: Resource?
  @OptionalParent(key: "repository_resource_id") var repositoryResource: Resource?
  @OptionalField(key: "training_datasheet_uuid") var trainingDatasheetUUID: String?
  @Timestamp(key: "created_at", on: .create) var createdAt: Date?
}
```

- [ ] **1.5** Write `PatraPlatform` migration. Enum values and the table go together — the table
  references no enum, so nothing here *uses* a value added in the same transaction.

```swift
_ = try await database.enum("platform").case("patra").update()
_ = try await database.enum("resource_type").case("agent").update()
_ = try await database.enum("metric_type").case("deployments").update()

try await database.schema("patra_cards")
  .id()
  .field("resource_id", .uuid, .required, .references("resources", "id", onDelete: .cascade))
  .field("card_uuid", .string, .required)
  .field("version", .string)
  .field("card_updated_at", .datetime)
  .field("source_url", .string)
  .field("hub_resource_id", .uuid, .references("resources", "id", onDelete: .setNull))
  .field("repository_resource_id", .uuid, .references("resources", "id", onDelete: .setNull))
  .field("training_datasheet_uuid", .string)
  .field("created_at", .datetime)
  .unique(on: "card_uuid")
  .create()
```

  `revert` drops the table only. PostgreSQL has no `ALTER TYPE … DROP VALUE`, and rebuilding the
  type would mean rewriting `accounts.platform`, `resources.type` and `metric_watermarks.type`.
  Say so in the doc comment — `CollectionBackoff` sets the precedent.

  **Soft deletes need no partial index**: a deleted resource keeps its card rows, so the sync
  follows the uuid, sees `deleted_at`, and skips.

- [ ] **1.6** Register in `configure.swift` after `CollectionBackoff()`.
- [ ] **1.7** Test: create an account on `.patra` with a `.model` resource and a card; re-save a
  second card with the same `card_uuid` and assert it fails. Run `just test`, `just fmt`, commit.

---

## Phase 2 — API client

### Task 2: `PatraAPI` wire types and paging

**Files:** create `Services/Patra/PatraAPI.swift`.

**Produces:** `PatraModelCard`, `PatraDatasheet`, `PatraModelCardDetail`, `PatraAPI.page(_:)`.

Three traps to encode, all verified:

- [ ] **2.1** Wire types with explicit `CodingKeys` — the JSON is snake_case:

```swift
struct PatraModelCard: Content {
  let uuid: String
  let name: String
  let version: String?
  let isPrivate: Bool?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case uuid, name, version
    case isPrivate = "is_private"
    case updatedAt = "updated_at"
  }
}
```

  `PatraDatasheet` is the same with `title` and `is_private`. Dates arrive as
  `2026-07-30T16:38:28.157335+00:00` — decode as `String` and parse explicitly rather than trusting
  the decoder's default strategy:

```swift
/// `.withFractionalSeconds` is required: Patra sends microseconds, and the formatter returns
/// nil for the whole string without it rather than truncating.
static let timestamps: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()
```

- [ ] **2.2** Deployments decode into an **empty** struct:

```swift
/// Only the count is used, and an empty Decodable accepts any object — so a new field or a
/// changed type upstream cannot break the metric.
struct PatraDeployment: Content {}
```

- [ ] **2.3** The paging loop. **This is the defect most likely to ship working and break later** —
  `/modelcards` returns 37 today against a default page of 50, and MegaDetector `6b-yolov9c` is
  already at 38 deployments:

```swift
/// Pages until a short page returns. `limit` is capped at 100 server-side; anything larger is
/// a 422, so this asks for exactly the maximum.
static func page<T: Content>(
  _ context: QueueContext, path: String, as: T.Type
) async throws -> [T] {
  let limit = 100
  var skip = 0
  var all: [T] = []
  while true {
    let url = URI(string: "\(baseURL)\(path)?skip=\(skip)&limit=\(limit)")
    let response = try await context.application.client.get(url)
    guard response.status == .ok else {
      throw JobError.apiRequestFailed(url: url.string, statusCode: Int(response.status.code), message: nil)
    }
    let batch: [T]
    do { batch = try response.content.decode([T].self) }
    catch { throw JobError.decodingFailed(url: url.string, underlying: error) }
    all += batch
    if batch.count < limit { return all }
    skip += limit
  }
}
```

- [ ] **2.4** Commit.

### Task 3: A query-aware test stub

**Files:** modify `Tests/InsightsTests/TestSupport.swift`.

**Why this is its own task:** `StubRoute` keys on `request.url.path` and *excludes the query string*
(TestSupport.swift:415-420). Every route therefore returns one fixed body, so **the pagination loop
cannot be tested with the existing helper** — page 2 would return page 1 forever.

- [ ] **3.1** Add a sibling that varies by full URL, leaving `stubAPI` untouched so no existing test
  changes:

```swift
/// `stubAPI` for endpoints whose *query* decides the answer.
///
/// `StubRoute` deliberately ignores the query string so the Hub's `expand[]` can vary freely.
/// Paging is the opposite case: `?skip=0` and `?skip=100` must answer differently, or a loop
/// that never advances still passes.
func stubPagedAPI(
  on app: Application,
  _ respond: @escaping @Sendable (String) -> ClientResponse?
) -> NIOLockedValueBox<[ClientRequest]>
```

  Unmatched requests answer 404, matching `stubAPI`'s contract — a job asking for an unanticipated
  URL should surface, not silently succeed.

- [ ] **3.2** Test it directly: two skips, two bodies. Commit.

---

## Phase 3 — Collection

### Task 4: `SyncPatraCatalog` — discovery

**Files:** create `Queues/Collectors/SyncPatraCatalog.swift`; modify `SyncJobTests.swift`.

**Consumes:** `PatraAPI` (Task 2), `PatraCard` (Task 1), `stubPagedAPI` (Task 3).
**Produces:** `SyncPatraCatalog`, payload `PatraAccount { let id: UUID }`.

Payload is an **account** id — the first job of this shape. `SyncGitHubOrgStats` is account-level
too but updates one field rather than creating rows.

- [ ] **4.1** Failing test — idempotency, the reason the table exists:

```swift
@Test("Re-running the catalog sync adds nothing")
func catalogSyncIsIdempotent() async throws { /* run twice, assert 23 resources and 37 cards both times */ }
```

- [ ] **4.2** Run it; expect a compile failure.
- [ ] **4.3** Implement. Rules, in order:

| Situation | Behaviour |
|---|---|
| `card_uuid` already in `patra_cards` | Skip — the idempotency guarantee |
| Model name unseen | Create Resource (`.model`), then its card |
| Model name known | Attach the card to the existing Resource |
| Datasheet title unseen | Create Resource (`.dataset`), then its card |
| `is_private == true` | Skip the card entirely |
| Card's resource is soft-deleted | Skip — an admin deletion means "stop tracking" |
| Known uuid, changed name | Keep the attachment, **log** the rename |

  New resources get `nextCollectionAt = now` so the next sweep measures them.

  **Do not call `recordSuccessfulCollection`.** It anchors per-resource cadence and backoff; this
  job is account-level and writes no metrics. Comment the deviation — `add-a-collector.md` says the
  opposite for the per-resource case.

- [ ] **4.4** Green. Then add: pagination past 50 (60 stubbed cards, via `stubPagedAPI`); grouping
  (11 MegaDetector cards → 1 resource, 11 cards); private card skipped; soft-deleted not
  resurrected; null `version` stored as null (`Yield Estimation` is the live case); rename logs
  without duplicating.
- [ ] **4.5** `just test`, `just fmt`, commit.

### Task 5: Provenance resolution

**Files:** modify `SyncPatraCatalog.swift`, `Services/Patra/PatraAPI.swift`.

**Verified:** `ModelCardDetail.ai_model` → `AIModel.location`; `ModelCardDetail` also carries
`training_datasheet_uuid`.

- [ ] **5.1** Add `PatraModelCardDetail` with nested `ai_model`, and a `detail(uuid:)` fetch.
  `location` lives on the detail, not the summary, so this is one extra request per card — 37 today.
- [ ] **5.2** Failing test: a `huggingface.co` URL lands in `hub_resource_id`, a `github.com` URL in
  `repository_resource_id`, an unknown host stores `source_url` and leaves both null.
- [ ] **5.3** Implement host-based resolution. **Store `source_url` regardless.** Resolution fails
  whenever the counterpart is not registered here, and a bare null cannot distinguish that from
  Patra having claimed nothing.

  Neither column names a platform: they point at `resources`, whose account carries the platform, so
  a GitLab repository resolves into the same column and the UI reads the platform off the link.

- [ ] **5.4** Failing test for **late resolution** — a card collected before its Hugging Face
  counterpart is registered resolves to null, then links on the next sweep.
- [ ] **5.5** Implement: resolution re-runs every sweep, not only at creation. This is the one place
  the job updates an existing row, and it is safe because it only fills a null or corrects a link —
  it never touches a name, version, or metric. Say that in the comment.
- [ ] **5.6** `just test`, `just fmt`, commit.

### Task 6: `SyncPatraDeployments`

**Files:** create `Queues/Collectors/SyncPatraDeployments.swift`; modify `SyncJobTests.swift`.

**Produces:** `SyncPatraDeployments`, payload `PatraResource { let id: UUID }`.

Routes through `dispatchSync` like every other per-resource collector, inheriting the capped backoff
and failure classification. Possible only because `patra_cards` lets a resource answer which uuids
are its own.

- [ ] **6.1** Failing test: a resource with two cards at 38 and 14 deployments records **52**.
- [ ] **6.2** Implement — read the resource's cards, page each `/modelcard/{uuid}/deployments`, sum,
  write one `.deployments` `Metric`, then `recordSuccessfulCollection` **last**.
- [ ] **6.3** Add: a `.dataset` resource records success and **no reading** (no such endpoint); a
  model with zero deployments records **0**, because the endpoint answered and 0 is what it said;
  vanished resource calls `entryVanished` and returns.
- [ ] **6.4** `just test`, `just fmt`, commit.

### Task 7: Routing and scheduling

**Files:** modify `Queues/Collectors/SyncDispatch.swift`, `configure.swift`; create
`Queues/Scheduled/CollectPatraCatalog.swift`; modify `QueueSweepTests.swift`.

- [ ] **7.1** Failing test in `QueueSweepTests`: a due `patra` resource dispatches
  `SyncPatraDeployments` and re-books.
- [ ] **7.2** Move `.patra` out of the skipped list in `dispatchSync`.
- [ ] **7.3** Write `CollectPatraCatalog`, modelled on `CollectAccountStats` — filter
  `platform == .patra`, `recordSchedulerHeartbeat`, dispatch per account, log and continue on error.
  **Daily**, not monthly: separate from `CollectAccountStats` because the unit differs, exactly as
  that job argues for being separate from `CollectDueResources`.
- [ ] **7.4** Register both jobs with `app.queues.add(...)` and schedule the daily sweep beside the
  existing registrations. **The scheduler runs exactly one replica** — do not add a second.
- [ ] **7.5** `just test`, `just fmt`, commit.

---

## Phase 4 — Seed and API

### Task 8: Development seed

**Files:** create `Migrations/PatraCatalogAugust2026.swift`; modify `configure.swift`; move
`patra-modelcards.json` → `data/`, `patra-datasets.json` → `data/patra-datasheets.json`.

- [ ] **8.1** Move the exports into `data/` as the provenance record, matching how
  `ICICLESnapshotJuly2026` cites its source. Rename to `datasheets` — what the endpoint calls them.
- [ ] **8.2** Generate the seed as **Swift literals** (a migration reading files at runtime depends
  on the working directory and on those files reaching the container image). 29 resources, 43 cards,
  and 3 readings: MegaDetector 52, ResNet50 16, MobileNetV2 1.
  **Carry the real card uuids** — a dev database seeded with invented ones re-registers all 43 on
  the first sync.
- [ ] **8.3** Register inside the existing `if app.environment == .development` block.
- [ ] **8.4** `just test`, `just fmt`, commit.

### Task 9: Expose links

**Files:** modify `DTOs/ResourceDTO.swift`.

- [ ] **9.1** Failing test: a resource with a hub link returns it from `GET /resources/:id`.
- [ ] **9.2** Add `links: [ResourceLink]?` to `Resource.Public` — each entry the linked resource's
  `id`, `name`, `platform`. Every field on `Public` is optional because `toPublic()` projects
  `$field.value`; keep that contract. Card versions stay unexposed — bookkeeping, not API.
- [ ] **9.3** `just test`, `just fmt`, commit.

---

## Phase 5 — Dashboard

### Task 10: Types, labels, colours

**Files:** modify `core/api/models.ts`, `shared/format/labels.ts`, `shared/charts/chart-palette.ts`,
`styles.css`, `shared/format/labels.spec.ts`.

- [ ] **10.1** `Platform` += `'patra'`, `ResourceType` += `'agent'`, `MetricType` += `'deployments'`.
- [ ] **10.2** `PLATFORM_LABELS.patra = 'Patra'`; **append** to `PLATFORM_ORDER`; add `'patra'` to
  the `models` group — already labelled "Models & Datasets" because Hugging Face spans both, so this
  extends the pattern rather than breaking it, and the picker renders "Hugging Face + Patra".
  Add `'agent'` first in `RESOURCE_TYPE_ORDER`.
- [ ] **10.3** `--ins-platform-patra` in **both** light and dark blocks; add to
  `chart-palette.ts` `FALLBACK.platforms`. No `METRIC_LABELS` entry — that map exists only for
  metrics whose bare name overstates their window, and a deployment count is honest.
- [ ] **10.4** Update `labels.spec.ts`. Run the dashboard tests, commit.

### Task 11: The provenance graph

**Files:** create `charts/provenance-graph.ts` and its spec; modify `dashboard.html`.

Follow [release-graph.ts](Dashboard/src/app/features/dashboard/charts/release-graph.ts) closely —
same `forceLayout`, `dot`/`link`/`text` marks, and the paired accessible table that makes the chart
readable without seeing it.

- [ ] **11.1** Vertices are **resources**, edges are provenance links. CAN Benchmark renders as
  three nodes: the GitHub repository, the Hugging Face dataset, the Patra datasheet.
- [ ] **11.2** Two-line labels via the existing `lines: readonly string[]` wrapping:

```
MegaDetector
(Hugging Face)
```

  Second line is `platformLabel(platform)` — each project's own spelling, already handled.

- [ ] **11.3** Colour by `palette.platforms[platform]`, **not** a series slot. A Hugging Face node
  is then the same hue as the Hugging Face slice in the composition chart beside it, which is why
  those tokens exist separately from the eight categorical slots.
- [ ] **11.4** Spec: two-line labels, platform colours, and a resource with no links.
- [ ] **11.5** Commit.

### Task 12: Documentation

**Files:** `docs/reference/collection-schedule.md`, `data-model.md`, `glossary.md`,
`docs/how-to/add-a-resource.md`, `add-a-collector.md`, `register-an-account.md`,
`docs/reference/admin-console.md`, `docs/explanation/the-dashboard.md`, `docs/README.md`, `TODO.md`.

- [ ] **12.1** One mode per page; verify every claim against the code, not another doc; tag line on
  each. `add-a-collector.md` gains the two deviations: first credential-free collector, and an
  account-level job that deliberately skips `recordSuccessfulCollection`.
- [ ] **12.2** `TODO.md` records the `agent` gap — the type exists, nothing publishes agents.
- [ ] **12.3** Add new pages to the `docs/README.md` index. Commit.

---

## Verification

```bash
just fmt
just test
```

Then, against a real boot — `.testing` skips paths where two real bugs have already hidden:

```bash
just migrate
just run
```

- [ ] Register the `icicleai` account on `patra` through the console.
- [ ] `just collect --force`; watch the worker log for the paged requests and written rows.
- [ ] Confirm 29 resources, 43 cards, and readings of 52 / 16 / 1.
- [ ] Load the dashboard; check the Patra hue and the provenance graph's two-line labels in **both**
  themes.

### Blocking risk

**`location` is unverified.** The schema says `AIModel.location` exists; whether it is populated,
and whether it holds a URL rather than a filesystem path, was never checked — the Patra pod stopped
first. **Task 5 cannot be completed honestly until the pod is back.** If `location` turns out to be
unusable, the columns stay and are filled by an administrator instead; Tasks 1–4 and 6–12 are
unaffected. Do Task 5 last, or stub it and revisit.

### Lesser risks

- **PostgreSQL 18 `ADD VALUE` semantics** are unverified. The design is safe either way because the
  enum and seed migrations are separate. Confirm on the first real `just migrate`.
- **Daily catalog cadence is a guess** at ICICLE's publishing rhythm. Cheap to change.
- **Expect the dataset count to rise by three.** Links make duplication visible but do not
  deduplicate totals — CAN Benchmark still counts as three resources. That is the honest count of
  registry entries, but someone will ask.
