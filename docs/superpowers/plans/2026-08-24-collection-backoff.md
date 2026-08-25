# Bounded Collection Backoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop failed collections from costing a full collection interval each, so gaps between successful collections stay inside GitHub's 14-day traffic retention window instead of compounding without bound.

**Architecture:** The hourly sweep keeps advancing `nextCollectionAt` at dispatch time — that advance is re-read as a *lease*, not a schedule. Two new nullable columns record when a resource last succeeded and whether its data-loss alert has fired. On an exhausted non-credential failure, the resource is re-booked on a capped backoff (1h–12h) derived from how overdue it is, rather than being left on the full-interval lease. A separate critical alert fires once per outage when a GitHub resource's gap since last success passes 14 days, which is the moment days become unrecoverable.

**Tech Stack:** Swift 6.3, Vapor 4, FluentKit + FluentPostgresDriver, SQLKit raw queries, swift-testing (`@Test` / `@Suite`), Valkey via queues-redis-driver.

**Spec:** [docs/superpowers/specs/2026-08-24-collection-backoff-design.md](../specs/2026-08-24-collection-backoff-design.md)

## Global Constraints

- **Comments explain *why*, not what.** The existing comments record rejected alternatives and non-obvious failure modes. Do not strip them. Add rationale, not restatement.
- **Doc-comment every type and non-trivial function**: one summary line, then rationale.
- `swift-format` is authoritative. Run `just fmt` before every commit.
- **Jobs must be retry-safe.** Queue delivery is at-least-once.
- **Secrets never enter logs or the database.**
- **Fold only completed UTC days newer than the metric watermark.** No task here changes fold logic; if a change seems to require it, stop and re-read the spec.
- Tests run serially against the `test` database: `just test`. A single suite:
  `swift test --no-parallel --filter "<TypeName>"`. **`--filter` matches the test struct's type
  name, not its `@Suite` display string.** `--filter "JobFailureTests"` selects 14 tests;
  `--filter "Job failure handling"` selects zero and reports a pass. A vacuous green is the one
  test result that looks like success and proves nothing — always confirm the run reports a
  non-zero test count.
- `.testing` skips the Tapis tenant key fetch and vault keyset read. Nothing in this plan touches those paths, so the suite is sufficient — no staging run required.
- Do **not** change `Metric+AllTime.swift`, `MetricWatermark`, or `CollectDueResources.swift`. The sweep's dispatch-time advance is deliberately retained.

---

### Task 1: Schema and model fields

Adds the two columns the whole design rests on, and clamps any GitHub resource already configured above the new interval cap.

**Files:**
- Create: `Sources/Insights/Migrations/CollectionBackoff.swift`
- Modify: `Sources/Insights/Models/Resource.swift`
- Modify: `Sources/Insights/configure.swift` (migration registration, near line 105)
- Test: `Tests/InsightsTests/JobFailureTests.swift`

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces: `Resource.lastCollectedAt: Date?`, `Resource.stallNotifiedAt: Date?`, and migration `CollectionBackoff`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/InsightsTests/JobFailureTests.swift`, inside the `JobFailureTests` suite, under a new `// MARK: - Scheduling state` section:

```swift
@Test
func `A resource carries nullable collection-history fields`() async throws {
  try await withInsightsApp { app in
    let resource = try await makeDueRepo(on: app)

    // Nil on a fresh row: nothing has collected it yet, and the backoff anchors on createdAt
    // until something does.
    #expect(resource.lastCollectedAt == nil)
    #expect(resource.stallNotifiedAt == nil)

    let stamped = Date()
    resource.lastCollectedAt = stamped
    resource.stallNotifiedAt = stamped
    try await resource.save(on: app.db)

    let reloaded = try #require(try await Resource.find(resource.id, on: app.db))
    #expect(abs(try #require(reloaded.lastCollectedAt).timeIntervalSince(stamped)) < 1)
    #expect(abs(try #require(reloaded.stallNotifiedAt).timeIntervalSince(stamped)) < 1)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: FAIL — compile error, `value of type 'Resource' has no member 'lastCollectedAt'`.

- [ ] **Step 3: Add the model fields**

In `Sources/Insights/Models/Resource.swift`, after the `collectionIntervalDays` property:

```swift
  /// When a collection last *succeeded*. The gap between successes is what the provider's
  /// retention window governs, so this — not `nextCollectionAt` — is what the backoff and the
  /// data-loss guard measure from. Nil until the first success; callers fall back to `createdAt`.
  @OptionalField(key: "last_collected_at")
  var lastCollectedAt: Date?

  /// When this resource's retention-window alert last fired, cleared on the next success.
  /// Without it the alert would repeat on every failure for the rest of the outage, which is
  /// exactly the noise the capped backoff exists to avoid.
  @OptionalField(key: "stall_notified_at")
  var stallNotifiedAt: Date?
```

Add both to `init`, defaulted so no existing caller changes:

```swift
    nextCollectionAt: Date? = nil,
    collectionIntervalDays: Int = Resource.defaultCollectionIntervalDays,
    lastCollectedAt: Date? = nil,
    stallNotifiedAt: Date? = nil,
```

and in the body, after `self.collectionIntervalDays = collectionIntervalDays`:

```swift
    self.lastCollectedAt = lastCollectedAt
    self.stallNotifiedAt = stallNotifiedAt
```

- [ ] **Step 4: Write the migration**

Create `Sources/Insights/Migrations/CollectionBackoff.swift`:

```swift
import Fluent
import FluentSQL
import SQLKit

/// Adds the collection history the failure backoff reads, and brings any over-long GitHub cadence
/// inside the new cap.
///
/// Additive on top of `RecurringCollection`, which is already applied to deployed databases.
struct CollectionBackoff: AsyncMigration {
  /// Adds the history columns and clamps GitHub cadences to the new maximum.
  func prepare(on database: any Database) async throws {
    try await database.schema("resources")
      .field("last_collected_at", .datetime)
      .field("stall_notified_at", .datetime)
      .update()

    // Both columns stay NULL for existing rows on purpose: a NULL `last_collected_at` means "no
    // success recorded", and the backoff falls back to `created_at`. Backfilling it with now()
    // would claim a success that never happened and suppress the data-loss alert for one full
    // retention window.

    guard let sql = database as? any SQLDatabase else { return }

    // GitHub's accepted cadence drops from 14 days to 7, because at 14 the sweep interval equals
    // the traffic retention window and there is no headroom for any delay at all. Nothing in the
    // repository seeds such a row, so this is defensive.
    try await sql.raw(
      """
      UPDATE resources
      SET collection_interval_days = 7
      WHERE collection_interval_days > 7
        AND account_id IN (SELECT id FROM accounts WHERE platform = 'github')
      """
    ).run()
  }

  /// Removes the history columns.
  ///
  /// One-way with respect to the cadence clamp: the original values are not recorded anywhere, so
  /// a revert cannot restore them. Reverting leaves every clamped resource at 7 days, which is a
  /// valid cadence under either cap.
  func revert(on database: any Database) async throws {
    try await database.schema("resources")
      .deleteField("last_collected_at")
      .deleteField("stall_notified_at")
      .update()
  }
}
```

- [ ] **Step 5: Register the migration**

In `Sources/Insights/configure.swift`, after `app.migrations.add(JobFailures())`:

```swift
  app.migrations.add(CollectionBackoff())
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
just fmt
git add Sources/Insights/Migrations/CollectionBackoff.swift Sources/Insights/Models/Resource.swift Sources/Insights/configure.swift Tests/InsightsTests/JobFailureTests.swift
git commit -m "Record when a collection last succeeded

The gap between successful collections is what a provider's retention
window governs, and nothing recorded it. Adds last_collected_at and the
stall_notified_at flag the data-loss alert will need, both nullable so
existing rows stay honest about never having collected."
```

---

### Task 2: Platform retention metadata and the interval cap

Separates "the longest cadence we accept" from "what the provider still returns", and lowers GitHub's accepted cadence so backoff has room to spend.

**Files:**
- Modify: `Sources/Insights/Models/Account.swift:12-18`
- Test: `Tests/InsightsTests/ResourceControllerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Platform.maxCollectionIntervalDays` (GitHub now `7`), `Platform.retentionWindowDays: Int?` (`14` for `.github`, `nil` otherwise).

**Note on the spec:** the spec described both `foldsRollingWindows: Bool` and `retentionWindowDays`. They are perfectly correlated, so this collapses them into one optional: `nil` *means* "cannot lose data to a retention window". Do not add the boolean.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/InsightsTests/ResourceControllerTests.swift`:

```swift
@Test
func `Create rejects a GitHub cadence with no headroom for delay`() async throws {
  try await withInsightsApp { app in
    let account = try await makeAccount(on: app.db, platform: .github)
    // 14 was accepted before: it equals the traffic retention window exactly, so any delay at
    // all loses days and no backoff value can protect it.
    let payload = Resource.Create(
      name: "insights", type: .repository, accountID: try account.requireID(),
      collectionIntervalDays: 14)

    try await app.testing().test(
      .POST,
      "api/resources",
      headers: app.adminAuth,
      beforeRequest: { req in try req.content.encode(payload) },
      afterResponse: { res async throws in
        #expect(res.status == .badRequest)
      },
    )
  }
}

@Test
func `The Hub keeps its longer cadence, having no window to lose`() {
  // The Hub reports downloadsAllTime outright, so a missed sweep costs series density and never
  // all-time correctness. Restricting it would buy nothing.
  #expect(Platform.huggingface.maxCollectionIntervalDays == 30)
  #expect(Platform.huggingface.retentionWindowDays == nil)
  #expect(Platform.github.maxCollectionIntervalDays == 7)
  #expect(Platform.github.retentionWindowDays == 14)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter "ResourceControllerTests"`
Expected: FAIL — compile error, `Platform has no member 'retentionWindowDays'`.

- [ ] **Step 3: Update Platform**

Replace the `maxCollectionIntervalDays` property in `Sources/Insights/Models/Account.swift` with:

```swift
  /// Longest cadence the API accepts for this platform.
  ///
  /// Not the same as the retention window, and deliberately shorter than it where one exists: a
  /// cadence equal to the window leaves no headroom, so a single delayed sweep loses days. GitHub
  /// is capped at half its 14-day window, which is room for one missed collection plus the
  /// failure backoff. The Hub has no window to lose against, so its limit is about series
  /// density rather than correctness.
  var maxCollectionIntervalDays: Int {
    switch self {
    case .github: 7
    case .huggingface: 30
    case .ghcr, .npm, .pypi: 30
    }
  }

  /// How far back the provider still returns daily values, when its metrics are rolling windows
  /// folded through a watermark.
  ///
  /// Nil means this platform cannot lose data to a window at all. The Hub reports
  /// `downloadsAllTime` itself and `Metric.setAllTime` assigns it, so a late sweep costs nothing
  /// permanently; only GitHub's `clones` and `views` are accumulated day by day and age out.
  var retentionWindowDays: Int? {
    switch self {
    case .github: 14
    case .ghcr, .huggingface, .npm, .pypi: nil
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter "ResourceControllerTests"`
Expected: PASS. The existing test `Update rejects a cadence beyond the account platform's retention window` uses 30 against GitHub and still expects a 400 — it stays valid under the lower cap.

- [ ] **Step 5: Run the whole suite**

Run: `just test`
Expected: all tests pass. If any test sets a GitHub cadence between 8 and 14, lower it to 7 — no such test existed at the time of writing.

- [ ] **Step 6: Commit**

```bash
just fmt
git add Sources/Insights/Models/Account.swift Tests/InsightsTests/ResourceControllerTests.swift
git commit -m "Give a GitHub cadence room for one missed collection

collectionIntervalDays was capped at the retention window itself, so an
interval of 14 on GitHub meant the sweep cadence equalled the window and
any delay at all aged days out. Caps it at half the window instead, and
separates 'longest cadence accepted' from 'what the provider still
returns' — the Hub has no window to lose, reporting its lifetime total
outright."
```

---

### Task 3: The backoff policy

A pure, DB-free unit so the curve can be tested directly rather than through a `QueueContext`.

**Files:**
- Create: `Sources/Insights/Queues/Support/CollectionSchedule.swift`
- Test: `Tests/InsightsTests/JobFailureTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `CollectionSchedule.minimumRetry: TimeInterval` (3600)
  - `CollectionSchedule.maximumRetry: TimeInterval` (43200)
  - `CollectionSchedule.overdue(now:lastSuccess:createdAt:intervalDays:) -> TimeInterval`
  - `CollectionSchedule.retryDelay(overdueBy:) -> TimeInterval`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/InsightsTests/JobFailureTests.swift` under a new `// MARK: - Backoff policy` section:

```swift
@Test
func `Backoff starts at an hour and never dips below it`() {
  // A resource failing right on schedule is barely overdue; retry on the next sweep.
  #expect(CollectionSchedule.retryDelay(overdueBy: 0) == 3600)
  #expect(CollectionSchedule.retryDelay(overdueBy: -86_400) == 3600)
  #expect(CollectionSchedule.retryDelay(overdueBy: 3600) == 3600)
}

@Test
func `Backoff grows with how overdue the resource is, then caps`() {
  // A quarter of the overdue time: gentle enough that the first day keeps retrying hourly,
  // steep enough to reach the ceiling after roughly two days of continuous failure.
  #expect(CollectionSchedule.retryDelay(overdueBy: 8 * 3600) == 2 * 3600)
  #expect(CollectionSchedule.retryDelay(overdueBy: 24 * 3600) == 6 * 3600)

  // The cap has to stay far inside `retention - interval` (7 days at GitHub's cap), or the
  // policy itself would be what loses the data.
  #expect(CollectionSchedule.retryDelay(overdueBy: 2 * 86_400) == 12 * 3600)
  #expect(CollectionSchedule.retryDelay(overdueBy: 60 * 86_400) == 12 * 3600)
}

@Test
func `Overdue time is measured from the last success, not the last attempt`() {
  let now = Date()
  let lastWeek = now.addingTimeInterval(-7 * 86_400)

  // Succeeded 7 days ago on a 7-day cadence: due now, not yet overdue.
  #expect(
    abs(
      CollectionSchedule.overdue(
        now: now, lastSuccess: lastWeek, createdAt: lastWeek, intervalDays: 7)) < 1)

  // Never succeeded: createdAt is the anchor, so a resource created 10 days ago on a 7-day
  // cadence is 3 days overdue rather than indefinitely patient.
  let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
  #expect(
    abs(
      CollectionSchedule.overdue(
        now: now, lastSuccess: nil, createdAt: tenDaysAgo, intervalDays: 7) - 3 * 86_400) < 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: FAIL — `cannot find 'CollectionSchedule' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Insights/Queues/Support/CollectionSchedule.swift`:

```swift
import struct Foundation.Date
import typealias Foundation.TimeInterval

/// When to try a resource again after a collection failed.
///
/// Kept apart from the failure reporter so the curve can be tested as arithmetic, without a
/// `QueueContext` or a database, and so the one place that decides "how long until the next
/// attempt" is findable by name.
///
/// The shape of the curve matters less than its ceiling. `CollectDueResources` advances a
/// resource's due date when it *dispatches*, so before this existed a failed collection cost a
/// full interval and gaps between successes compounded while the provider's retention window did
/// not. Anything that re-books inside the window fixes that; the curve just decides how much
/// noise the fix makes on the way.
enum CollectionSchedule {
  /// Never sooner than the sweep that would pick it up anyway — `CollectDueResources` runs
  /// hourly, so a shorter delay only waits for the same tick.
  static let minimumRetry: TimeInterval = 3600

  /// Never later than this, whatever the arithmetic says.
  ///
  /// Twelve hours is far inside `retentionWindowDays - maxCollectionIntervalDays`, which is seven
  /// days at GitHub's cap. That margin is the point: the policy must never be the reason a day
  /// ages out. Only an outage longer than the window itself can do that, and the data-loss alert
  /// exists to say so when it happens.
  static let maximumRetry: TimeInterval = 12 * 3600

  /// How far past its due date this resource is, measured from its last *success*.
  ///
  /// The last attempt is the wrong anchor: attempts happen on every backoff tick, so measuring
  /// from one would reset the escalation each time and hold the resource at the minimum forever.
  ///
  /// - Parameters:
  ///   - now: The current instant.
  ///   - lastSuccess: When collection last succeeded, or nil if it never has.
  ///   - createdAt: Fallback anchor for a resource with no successful collection yet.
  ///   - intervalDays: The resource's configured cadence.
  /// - Returns: Seconds past due; negative when the resource is not due yet.
  static func overdue(
    now: Date,
    lastSuccess: Date?,
    createdAt: Date?,
    intervalDays: Int
  ) -> TimeInterval {
    let anchor = lastSuccess ?? createdAt ?? now
    return now.timeIntervalSince(anchor) - Double(intervalDays) * 86_400
  }

  /// How long to wait before the next attempt.
  ///
  /// A quarter of the overdue time, clamped. Front-loaded on purpose: early attempts can still
  /// recover every day in the window, so they are worth making often, while attempts made after
  /// days of failure are recovering less and less and are not worth alerting about as often.
  /// Retries stay hourly for roughly the first four hours and reach the ceiling after about two
  /// days.
  ///
  /// - Parameter overdue: Seconds past due, from ``overdue(now:lastSuccess:createdAt:intervalDays:)``.
  /// - Returns: Seconds to wait, always between ``minimumRetry`` and ``maximumRetry``.
  static func retryDelay(overdueBy overdue: TimeInterval) -> TimeInterval {
    min(max(overdue / 4, minimumRetry), maximumRetry)
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just fmt
git add Sources/Insights/Queues/Support/CollectionSchedule.swift Tests/InsightsTests/JobFailureTests.swift
git commit -m "Add the retry curve for failed collections

Pure arithmetic, kept out of the failure reporter so it can be tested
without a QueueContext. The ceiling is the load-bearing part: twelve hours
sits far inside the seven days of headroom a capped GitHub cadence leaves,
so the policy can never itself be the reason a traffic day ages out."
```

---

### Task 4: Recording a successful collection

Anchors the schedule on success rather than dispatch, and clears the stall flag.

**Files:**
- Modify: `Sources/Insights/Models/Resource.swift`
- Modify: `Sources/Insights/Queues/Collectors/SyncGitHubRepoStats.swift` (end of `dequeue`)
- Modify: `Sources/Insights/Queues/Collectors/SyncHuggingFaceHubStats.swift` (end of `dequeue`)
- Test: `Tests/InsightsTests/JobFailureTests.swift`

**Interfaces:**
- Consumes: `Resource.lastCollectedAt`, `Resource.stallNotifiedAt` (Task 1).
- Produces: `Resource.recordSuccessfulCollection(on:now:) async throws`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/InsightsTests/JobFailureTests.swift`, under `// MARK: - Scheduling state`:

```swift
@Test
func `A successful sweep anchors the schedule on the success`() async throws {
  try await withQueueApp { app in
    let resource = try await makeDueRepo(on: app)
    // Left over from a previous outage: a success has to clear it, or the data-loss alert
    // would stay suppressed through the next one.
    resource.stallNotifiedAt = Date().addingTimeInterval(-86_400)
    try await resource.save(on: app.db)

    stubAPI(
      on: app,
      [
        .ok(
          "/repos/icicle-ai/insights",
          #"{"stargazers_count": 1, "forks_count": 1, "subscribers_count": 1}"#),
        .ok("/repos/icicle-ai/insights/traffic/clones", #"{"count": 1, "uniques": 1, "clones": []}"#),
        .ok("/repos/icicle-ai/insights/traffic/views", #"{"count": 1, "uniques": 1, "views": []}"#),
      ])

    try await CollectDueResources().run(context: queueContext(for: app))
    try await app.queues.queue(.metrics).worker.run()

    let settled = try #require(try await Resource.find(resource.id, on: app.db))
    #expect(abs(try #require(settled.lastCollectedAt).timeIntervalSinceNow) < 60)
    #expect(settled.stallNotifiedAt == nil)
    // Re-booked a full interval out from the success, not from the dispatch that preceded it.
    #expect(
      abs(
        try #require(settled.nextCollectionAt).timeIntervalSinceNow - 7 * 86_400) < 60)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: FAIL — `lastCollectedAt` is nil, because nothing writes it yet.

- [ ] **Step 3: Add the model helper**

In `Sources/Insights/Models/Resource.swift`, after `scheduleNextCollection(from:)`:

```swift
  /// Records a completed collection and books the next one from it.
  ///
  /// The sweep advances `nextCollectionAt` when it dispatches, which is a lease rather than a
  /// schedule: it keeps the resource out of the next sweep while an outcome is outstanding. This
  /// is what settles it once the outcome is known, so the cadence anchors on the last success.
  ///
  /// Clearing `stallNotifiedAt` is what re-arms the retention-window alert. A resource that
  /// recovered and later stalls again is a new outage and deserves to be told about again.
  /// - Parameters:
  ///   - db: Database to save through.
  ///   - now: The instant the collection completed.
  func recordSuccessfulCollection(on db: any Database, now: Date = Date()) async throws {
    lastCollectedAt = now
    stallNotifiedAt = nil
    scheduleNextCollection(from: now)
    try await save(on: db)
  }
```

- [ ] **Step 4: Call it from the GitHub collector**

In `Sources/Insights/Queues/Collectors/SyncGitHubRepoStats.swift`, at the very end of `dequeue`, after the `for (traffic, endpoint)` fold loop closes:

```swift
    // Last, and only on the happy path: every fetch and both folds have to have succeeded before
    // this counts as a collection. A partial sweep must leave the schedule alone so the failure
    // handler can book a backoff instead.
    try await resource.recordSuccessfulCollection(on: context.application.db)
```

- [ ] **Step 5: Call it from the Hub collector**

In `Sources/Insights/Queues/Collectors/SyncHuggingFaceHubStats.swift`, at the very end of `dequeue`, after the `Metric.setAllTime` call:

```swift
    // Same contract as the GitHub collector: the schedule advances only once the whole sweep has
    // landed.
    try await resource.recordSuccessfulCollection(on: context.application.db)
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: PASS.

- [ ] **Step 7: Run the whole suite**

Run: `just test`
Expected: all pass. `QueueSweepTests` still passes — the sweep's dispatch-time advance is unchanged, and the success path now overwrites it with a value within a minute of the same instant.

- [ ] **Step 8: Commit**

```bash
just fmt
git add Sources/Insights/Models/Resource.swift Sources/Insights/Queues/Collectors/SyncGitHubRepoStats.swift Sources/Insights/Queues/Collectors/SyncHuggingFaceHubStats.swift Tests/InsightsTests/JobFailureTests.swift
git commit -m "Anchor the collection cadence on the last success

The sweep books the next collection when it dispatches, which is fine as a
lease but wrong as a schedule: it is set before anyone knows whether the
collection worked. Both collectors now settle the schedule themselves once
a whole sweep has landed, and clear the stall flag so a recovered resource
can raise a fresh alert if it stalls again."
```

---

### Task 5: Booking backoff on failure

The defect fix proper: the branch that currently returns without re-booking.

**Files:**
- Modify: `Sources/Insights/Queues/Support/FailureReporting.swift:64-81`
- Test: `Tests/InsightsTests/JobFailureTests.swift`

**Interfaces:**
- Consumes: `CollectionSchedule.overdue(...)`, `CollectionSchedule.retryDelay(overdueBy:)` (Task 3); `Resource.lastCollectedAt` (Task 1).
- Produces: no new public API — changes the behaviour of `QueueContext.reportResourceSyncFailure(_:job:resourceID:)`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/InsightsTests/JobFailureTests.swift` under `// MARK: - Rebooking`, and **delete the existing test** `A platform failure leaves the normal cadence alone`, whose premise this task reverses:

```swift
@Test
func `A platform failure re-books within the cap instead of costing an interval`() async throws {
  try await withInsightsApp { app in
    _ = stubNotifier(on: app)
    let resource = try await makeDueRepo(on: app)
    // A week out is where the sweep left it — it advances the due date on dispatch, long before
    // the job fails. Leaving it there is what let gaps compound past the retention window.
    resource.lastCollectedAt = past(7)
    resource.scheduleNextCollection()
    try await resource.save(on: app.db)

    try await SyncGitHubRepoStats().error(
      queueContext(for: app),
      JobError.decodingFailed(url: "https://api.github.com", underlying: Underlying()),
      .init(id: try resource.requireID()),
    )

    let rebooked = try #require(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
    // Barely overdue, so the floor applies: the next hourly sweep, not next week.
    #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
  }
}

@Test
func `A long-failing resource backs off but stays inside the window`() async throws {
  try await withInsightsApp { app in
    _ = stubNotifier(on: app)
    let resource = try await makeDueRepo(on: app)
    // Nine days since the last success on a 7-day cadence: two days overdue, so the ceiling.
    resource.lastCollectedAt = past(9)
    try await resource.save(on: app.db)

    try await SyncGitHubRepoStats().error(
      queueContext(for: app),
      JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
      .init(id: try resource.requireID()),
    )

    let rebooked = try #require(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
    #expect(abs(rebooked.timeIntervalSinceNow - 12 * 3600) < 60)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: FAIL — the due date is unchanged a week out, so `rebooked.timeIntervalSinceNow` is about 604800, not 3600.

- [ ] **Step 3: Replace the re-booking block**

In `Sources/Insights/Queues/Support/FailureReporting.swift`, replace everything from `guard error.isCredentialFailure, let resource else { return }` to the end of `reportResourceSyncFailure` with:

```swift
    guard let resource else { return }

    let now = Date()
    let retryAt: Date
    if error.isCredentialFailure {
      // Flat, and deliberately not escalating: the fix lands out of band and can land at any
      // moment, so there is no point spacing attempts out. See `credentialRetryInterval`.
      retryAt = now.addingTimeInterval(credentialRetryInterval)
    } else {
      // Everything else used to fall out here without re-booking, which meant the sweep's
      // dispatch-time advance stood: one failure cost a full interval, two put a GitHub resource
      // past its 14-day traffic window, and the days in between were gone for good.
      let overdue = CollectionSchedule.overdue(
        now: now,
        lastSuccess: resource.lastCollectedAt,
        createdAt: resource.createdAt,
        intervalDays: resource.collectionIntervalDays,
      )
      retryAt = now.addingTimeInterval(CollectionSchedule.retryDelay(overdueBy: overdue))
    }

    resource.nextCollectionAt = retryAt
    do {
      try await resource.save(on: application.db)
      logger.notice(
        "Resource re-booked after a failed collection",
        metadata: metadata.merging(["retry_at": .string("\(retryAt)")]) { _, new in new }
      )
    } catch {
      // The alert has already gone out, so the operator still knows. Losing the rebooking only
      // costs the automatic recovery, which is why this is reported rather than retried.
      logger.error(
        "Could not re-book the resource after a failed collection",
        metadata: metadata.merging(["error": .string(String(reflecting: error))]) { _, new in new }
      )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: PASS, including the untouched `A credential failure re-books the resource for the next hourly sweep` and `An unavailable vault is not treated as a credential failure`.

**Note:** `An unavailable vault is not treated as a credential failure` asserts the due date is *unchanged*. It will now fail, because a non-credential failure re-books. Update its final assertion to expect the hourly floor instead, keeping its doc comment — its point is the *severity*, not the cadence:

```swift
      #expect(notifier.recorded.first?.severity == .warning)
      let rebooked = try #require(try await Resource.find(resource.id, on: app.db)?.nextCollectionAt)
      #expect(abs(rebooked.timeIntervalSinceNow - 3600) < 60)
```

- [ ] **Step 5: Run the whole suite**

Run: `just test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
just fmt
git add Sources/Insights/Queues/Support/FailureReporting.swift Tests/InsightsTests/JobFailureTests.swift
git commit -m "Re-book a failed collection instead of skipping an interval

Only credential failures were re-booked; everything else — a 5xx, a 429, a
malformed body — returned without touching the schedule, so the sweep's
dispatch-time advance stood and the failure cost a full interval. Two in a
row put a GitHub resource past its 14-day traffic window and the days in
between were unrecoverable.

Non-credential failures now book a capped backoff measured from the last
success, so a failure costs hours. Credential failures keep their flat
hour: that fix lands out of band and can land at any moment."
```

---

### Task 6: The data-loss alert

The event nobody currently gets: the moment days become unrecoverable.

**Files:**
- Modify: `Sources/Insights/Queues/Support/FailureReporting.swift`
- Test: `Tests/InsightsTests/JobFailureTests.swift`

**Interfaces:**
- Consumes: `Platform.retentionWindowDays` (Task 2); `Resource.lastCollectedAt`, `Resource.stallNotifiedAt` (Task 1).
- Produces: no new public API. Emits a `FailureAlert` with `identifier: "collection_window_exceeded"` and persists a matching `JobFailure` row.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/InsightsTests/JobFailureTests.swift` under a new `// MARK: - Retention window` section:

```swift
@Test
func `Passing the retention window raises its own alert, once`() async throws {
  try await withInsightsApp { app in
    let notifier = stubNotifier(on: app)
    let resource = try await makeDueRepo(on: app)
    // 20 days since the last success, against GitHub's 14-day traffic window: days have already
    // aged out and cannot be reconstructed by any watermark.
    resource.lastCollectedAt = past(20)
    try await resource.save(on: app.db)

    try await SyncGitHubRepoStats().error(
      queueContext(for: app),
      JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
      .init(id: try resource.requireID()),
    )

    let breach = try #require(
      notifier.recorded.first { $0.identifier == "collection_window_exceeded" })
    #expect(breach.severity == .critical)
    #expect(breach.subject == "icicle-ai/insights")
    #expect(breach.details.contains("cannot be recovered"))

    let stamped = try #require(try await Resource.find(resource.id, on: app.db))
    #expect(stamped.stallNotifiedAt != nil)

    // Second failure in the same outage: the underlying error still alerts, the breach does not
    // repeat. The capped backoff already spaces those out; repeating this one would double it.
    try await SyncGitHubRepoStats().error(
      queueContext(for: app),
      JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
      .init(id: try resource.requireID()),
    )
    #expect(notifier.recorded.filter { $0.identifier == "collection_window_exceeded" }.count == 1)
  }
}

@Test
func `The Hub never raises a data-loss alert`() async throws {
  try await withInsightsApp { app in
    let notifier = stubNotifier(on: app)
    let account = try await makeAccount(on: app.db, name: "icicle", platform: .huggingface)
    let accountID = try account.requireID()
    _ = try await makeVault(on: app.db, accountID: accountID)
    let resource = try await makeResource(
      on: app.db, accountID: accountID, name: "insights", type: .model)
    // Far past any window, and still not a loss: the Hub reports downloadsAllTime outright, so
    // the next successful sweep restores the correct total.
    resource.lastCollectedAt = past(90)
    try await resource.save(on: app.db)

    try await SyncHuggingFaceHubStats().error(
      queueContext(for: app),
      JobError.apiRequestFailed(url: "https://huggingface.co", statusCode: 503, message: nil),
      .init(id: try resource.requireID()),
    )

    #expect(!notifier.recorded.contains { $0.identifier == "collection_window_exceeded" })
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: FAIL — no alert carries `collection_window_exceeded`.

- [ ] **Step 3: Split the persistence helper so it can record a non-error event**

In `Sources/Insights/Queues/Support/FailureReporting.swift`, replace the body of the existing private `persistFailure(_:job:subject:resourceID:accountID:)` with a call to a new overload, and add that overload beneath it:

```swift
  private func persistFailure(
    _ error: any Error,
    job: String,
    subject: String,
    resourceID: UUID? = nil,
    accountID: UUID? = nil
  ) async {
    await persistFailure(
      job: job,
      subject: subject,
      identifier: error.alertIdentifier,
      details: error.alertDetails,
      severity: error.isCredentialFailure ? "critical" : "warning",
      resourceID: resourceID,
      accountID: accountID,
    )
  }

  /// Persists one row of operational history from values rather than an error.
  ///
  /// The retention-window breach is a condition, not a thrown error — there is no `Error` to
  /// classify — but it belongs in the same history the admin console reads.
  ///
  /// This must never throw. QueueWorker awaits the job's error callback before clearing the job;
  /// propagating a database failure from here strands the failed job and can stop the worker.
  private func persistFailure(
    job: String,
    subject: String,
    identifier: String,
    details: String,
    severity: String,
    resourceID: UUID? = nil,
    accountID: UUID? = nil
  ) async {
    let failure = JobFailure(
      resourceID: resourceID,
      accountID: accountID,
      job: job,
      subject: subject,
      identifier: identifier,
      details: details,
      severity: severity
    )

    do {
      try await failure.create(on: application.db)
    } catch {
      logger.error(
        "Could not persist exhausted job failure; worker will continue.",
        metadata: [
          "job": .string(job),
          "subject": .string(subject),
          "error": .string(String(reflecting: error)),
        ]
      )
    }
  }
```

- [ ] **Step 4: Add the breach check**

In `reportResourceSyncFailure`, immediately **before** `resource.nextCollectionAt = retryAt` (added in Task 5), insert:

```swift
    await noteRetentionWindowBreach(
      resource, now: now, job: job, subject: subject ?? resourceID.uuidString, metadata: metadata)
```

Then add this private method to the same `extension QueueContext`:

```swift
  /// Alerts, once per outage, when a resource's gap since its last success has passed the window
  /// its provider still serves.
  ///
  /// This is the only place that reports data as *lost* rather than delayed. Every other failure
  /// says an attempt did not work; this one says the days in the gap are no longer obtainable
  /// from the provider and no watermark can reconstruct them.
  ///
  /// Mutates `stallNotifiedAt` on the passed resource without saving — the caller saves once,
  /// with the re-booking, so a breach and its backoff land in the same write.
  private func noteRetentionWindowBreach(
    _ resource: Resource,
    now: Date,
    job: String,
    subject: String,
    metadata: Logger.Metadata
  ) async {
    // Nil means the platform cannot lose data to a window at all — the Hub reports its lifetime
    // total outright, so a late sweep costs series density and nothing permanent.
    guard let windowDays = resource.account.platform.retentionWindowDays,
      resource.stallNotifiedAt == nil
    else { return }

    let anchor = resource.lastCollectedAt ?? resource.createdAt ?? now
    let gap = now.timeIntervalSince(anchor)
    guard gap > Double(windowDays) * 86_400 else { return }

    let gapDays = Int(gap / 86_400)
    let details = """
      No collection has succeeded for \(gapDays) days, past the \(windowDays)-day window \
      \(resource.account.platform.rawValue) still serves. Daily values older than that window are \
      no longer returned and cannot be recovered — the all-time total for this resource is now \
      permanently short by the days in the gap.
      Check this account's token and the platform's status. Collection resumes on its own once a \
      sweep succeeds; the missing days will not come back.
      """

    logger.critical(
      "Collection gap has passed the provider's retention window",
      metadata: metadata.merging([
        "gap_days": .string("\(gapDays)"), "window_days": .string("\(windowDays)"),
      ]) { _, new in new }
    )
    await application.notifier.notify(
      FailureAlert(
        severity: .critical,
        job: job,
        subject: subject,
        identifier: "collection_window_exceeded",
        details: details,
      ))
    await persistFailure(
      job: job,
      subject: subject,
      identifier: "collection_window_exceeded",
      details: details,
      severity: "critical",
      resourceID: resource.id,
      accountID: resource.$account.id,
    )

    resource.stallNotifiedAt = now
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter "JobFailureTests"`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `just test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
just fmt
git add Sources/Insights/Queues/Support/FailureReporting.swift Tests/InsightsTests/JobFailureTests.swift
git commit -m "Say when collection has actually lost data

Every failure alert says an attempt did not work. None said the days in
the gap are now unobtainable, which is the only one that needs a different
response — no retry recovers them.

Fires once per outage, when the gap since the last success passes the
window the provider still serves, and re-arms on the next success. Silent
for platforms reporting a lifetime total, which cannot lose data this way."
```

---

### Task 7: End-to-end proof and documentation

Proves the reported scenario is fixed, and updates every document the change makes wrong.

**Retargeted after the `main` merge (1d9e891).** The flat `docs/*.md` pages this task originally
named no longer exist — `main` restructured the documentation onto Diátaxis. Every path below is
the current one, verified against the tree. Do not recreate a deleted flat page.

**Files:**
- Test: `Tests/InsightsTests/MetricAllTimeTests.swift`
- Modify: `docs/reference/invariants.md` (Queues and scheduling table; Metrics table)
- Modify: `CLAUDE.md` ("Invariants worth stating here")
- Modify: `docs/reference/collection-schedule.md` (scheduling facts)
- Modify: `docs/explanation/watermarks.md` (the field-versus-question table, ~line 66)
- Modify: `docs/explanation/decisions/005-failure-alerting.md`
- Create: `docs/explanation/decisions/008-collection-backoff.md`
- Modify: `docs/explanation/decisions/README.md` (index table)
- Modify: `docs/README.md` (line ~82 says "Seven architecture decision records")

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: no code API.

**Documentation contract — binding, from `CLAUDE.md`:**
- **One mode per page.** `reference/` is tables, not narrative. `explanation/` is prose. A how-to
  states no rationale. Do not add paragraphs of reasoning to a reference page — put them in the ADR
  and link.
- **Verify every claim against the code**, never against another doc.
- Every page ends with a tag line: exactly one type tag (`#Tutorial#`, `#How-To#`, `#Reference#`,
  `#Explanation#`) and at least one audience tag (`#Administrator#`, `#Developer#`).
- Any new page joins the index table in `docs/README.md` in the same change. A new ADR also joins
  the table in `docs/explanation/decisions/README.md`.
- `docs/superpowers/` is explicitly exempt from the placement rule. Leave plans and specs alone.

- [ ] **Step 1: Write the scenario test**

Add to `Tests/InsightsTests/MetricAllTimeTests.swift`:

```swift
/// The case from the defect report. `CollectDueResources` advances the due date when it
/// dispatches, so before the fix a non-credential failure left that advance standing and cost a
/// full interval: day 7 booked day 14, day 14 booked day 21, and the response on day 21 no
/// longer reached back to day 0. Days 1-6 were in no folded response and could not be recovered.
///
/// The lease has to be applied for this to pin anything. An earlier version of this test set
/// `nextCollectionAt` once and fired two failures back to back; it passed against the pre-fix
/// code too, because the gap never grew.
@Test
func `A failed collection is pulled back inside the retention window`() async throws {
  try await withInsightsApp { app in
    _ = stubNotifier(on: app)
    let account = try await makeAccount(on: app.db, name: "icicle-ai", platform: .github)
    let accountID = try account.requireID()
    _ = try await makeVault(on: app.db, accountID: accountID)
    let resource = try await makeResource(
      on: app.db, accountID: accountID, name: "insights", type: .repository,
      collectionIntervalDays: 7)

    let daysAgo = { (d: Double) in Date().addingTimeInterval(-d * 86_400) }

    // Day 0 collected. Day 7 is due, and the sweep advances the lease a full interval before the
    // job runs. That advance is what the fix has to pull back.
    resource.lastCollectedAt = daysAgo(7)
    resource.scheduleNextCollection()
    try await resource.save(on: app.db)
    let leased = try #require(resource.nextCollectionAt)
    #expect(leased.timeIntervalSinceNow > 6 * 86_400)

    try await SyncGitHubRepoStats().error(
      queueContext(for: app),
      JobError.apiRequestFailed(url: "https://api.github.com", statusCode: 503, message: nil),
      .init(id: try resource.requireID()),
    )

    let settled = try #require(try await Resource.find(resource.id, on: app.db))
    let nextAttempt = try #require(settled.nextCollectionAt)

    // Before the fix this stayed a week out, and a second failure pushed it to day 21.
    #expect(nextAttempt.timeIntervalSinceNow <= CollectionSchedule.maximumRetry + 60)
    // The gap since the last success stays inside GitHub's 14-day traffic window, so the next
    // response still reaches back to day 0.
    #expect(nextAttempt.timeIntervalSince(daysAgo(7)) < 14 * 86_400)
    #expect(settled.stallNotifiedAt == nil)
  }
}
```

- [ ] **Step 2: Run it to verify it passes**

Run: `swift test --no-parallel --filter "MetricAllTimeTests"`
Expected: PASS, with a non-zero test count. This test verifies finished behaviour rather than
driving new code — Tasks 1–6 already implement it.

- [ ] **Step 3: Update the invariants reference**

`docs/reference/invariants.md` uses **tables**, not bullets. In the "Queues and scheduling" table,
replace the credential re-booking row with these two:

```markdown
| Every exhausted resource failure re-books its resource | The sweep's dispatch-time due date stands, so one failure costs a full cadence and gaps compound past the retention window |
| The failure backoff ceiling stays well inside `retentionWindowDays - maxCollectionIntervalDays` | The retry policy itself becomes the cause of a lost day |
```

In the "Metrics" table, replace the cadence row with:

```markdown
| Cadence stays at most half the platform's retention window | No headroom for a missed collection: one delayed sweep ages days out |
| A gap past the retention window raises `collection_window_exceeded`, once per outage | Data loss stays silent |
```

- [ ] **Step 4: Update CLAUDE.md**

In "Invariants worth stating here", after the "Jobs must be retry-safe" bullet:

```markdown
- **Failures re-book, they do not skip.** `CollectDueResources` advances `nextCollectionAt` at
  dispatch, which is a lease. An exhausted failure must replace it with a capped backoff, or two
  failures put a resource past its provider's retention window and the gap days are gone.
```

- [ ] **Step 5: Update the collection-schedule reference**

`docs/reference/collection-schedule.md` is a reference page: state the facts, do not explain them.
Add to the scheduling section:

```markdown
| State | Question it answers |
|---|---|
| `next_collection_at` | When may this be dispatched again |
| `last_collected_at` | When did a collection last succeed |
| `collection_interval_days` | Spacing booked after a success |

The dispatch-time advance is a lease, not the schedule. A successful sync re-books from the moment
it completed; an exhausted failure re-books on a capped backoff of 1 to 12 hours, scaled to how
overdue the resource is. See [ADR 008](../explanation/decisions/008-collection-backoff.md).
```

- [ ] **Step 6: Update the watermarks explanation**

In `docs/explanation/watermarks.md`, the field-versus-question table (~line 66) gains a row:

```markdown
| `lastCollectedAt` | When did a collection last succeed? |
```

- [ ] **Step 7: Amend ADR 005**

In `docs/explanation/decisions/005-failure-alerting.md`, amend the paragraph rationalising the
dispatch-time advance so it points forward. A record is history — correct the fact and supersede,
do not delete the decision:

```markdown
Credential failures were re-booked hourly from the start; every other failure was not, which
[ADR 008](008-collection-backoff.md) corrects.
```

- [ ] **Step 8: Write ADR 008**

Create `docs/explanation/decisions/008-collection-backoff.md`. Match the house style of 004 and
005 — situation, decision, what it costs — and end with a tag line:

```markdown
# ADR 008: Bounded backoff for failed collections

**Status:** Accepted

An exhausted non-credential failure re-books its resource on a capped backoff — a quarter of the
time it is overdue, clamped to 1–12 hours — instead of leaving the full-interval due date the sweep
set at dispatch. `Resource.lastCollectedAt` records the last success, and the backoff is measured
from it rather than from the last attempt, which would reset the escalation on every tick.

The dispatch-time advance stays. Read as a lease it is correct, and moving scheduling authority to
the job would strand the platforms that have no collector — `ghcr`, `npm` and `pypi` are dispatched
as no-ops and would never report an outcome to settle on. The defect was never the lease; it was
that nothing shortened it when the outcome turned out badly, so gaps compounded geometrically while
the provider's retention window stayed fixed.

The ceiling is load-bearing. Twelve hours sits far inside `retentionWindowDays -
maxCollectionIntervalDays`, which is why GitHub's accepted cadence dropped to 7: at 14 the cadence
equalled the window and there was no headroom for any delay, failure or not. With that margin the
policy can never be the cause of a lost day; only an outage longer than the window itself can be,
and `collection_window_exceeded` reports exactly that, once per outage.

Hugging Face is exempt from the guard. The Hub reports `downloadsAllTime` and `Metric.setAllTime`
assigns it, so a late sweep costs series density and nothing permanent. Only GitHub's watermark-
folded `clones` and `views` accumulate day by day and can age out.

#icicle-insights# #Explanation# #Developer# #decisions# #collection#
```

- [ ] **Step 9: Register the new record in both indexes**

In `docs/explanation/decisions/README.md`, add to the table:

```markdown
| [008](008-collection-backoff.md) | Failed collections back off, bounded | Accepted |
```

In `docs/README.md`, the decisions row says "Seven architecture decision records". Make it eight.

- [ ] **Step 10: Verify**

```bash
just test
```

Then confirm the documentation holds together:

```bash
grep -rn "collection_window_exceeded\|lastCollectedAt\|CollectionSchedule" docs CLAUDE.md
```

Check that every relative link in the pages you touched resolves, that each page still ends with
its tag line, and that no page you edited now states the cadence cap equals the retention window.

- [ ] **Step 11: Commit**

```bash
just fmt
git add Tests/InsightsTests/MetricAllTimeTests.swift docs CLAUDE.md
git commit -m "Document the collection backoff and prove the reported case

Pins the exact scenario from the report — two consecutive failures at the
default cadence — and asserts the next attempt still lands inside the
14-day window, where it used to land on day 21 with days 1-6 already gone.

Adds ADR 008, amends ADR 005 (which rationalised the un-re-booked failure
path), and states the new rule as an invariant: a failure re-books, it
does not skip."
```

---


## Self-Review

**Spec coverage:** Section 1 (new state) → Task 1. Section 2 (backoff policy) → Tasks 3 and 5. Section 3 (where the writes happen) → Task 4. Section 4 (data-loss guard, platform metadata, interval cap, migration clamp) → Tasks 2, 1 and 6. Section 5 (verification) → the tests in Tasks 1–6 plus Task 7. Section 6 (documentation) → Task 7. No gaps.

**Deliberate deviation from the spec:** the spec listed `foldsRollingWindows: Bool` and `retentionWindowDays` as separate members of `Platform`. They are perfectly correlated, so Task 2 collapses them into `retentionWindowDays: Int?`, where nil carries the boolean's meaning. Recorded here so a reader of both documents is not surprised.

**Type consistency:** `lastCollectedAt` and `stallNotifiedAt` are spelled identically in Tasks 1, 4, 5 and 6. `CollectionSchedule.overdue(now:lastSuccess:createdAt:intervalDays:)` and `.retryDelay(overdueBy:)` are defined in Task 3 and called with those exact labels in Task 5. `retentionWindowDays` is defined in Task 2 and read in Task 6. `recordSuccessfulCollection(on:now:)` is defined and called in Task 4.

**Tests this plan changes rather than adds:** `A platform failure leaves the normal cadence alone` is deleted in Task 5 — its premise is the defect. `An unavailable vault is not treated as a credential failure` keeps its purpose but its final assertion is updated in the same task.
