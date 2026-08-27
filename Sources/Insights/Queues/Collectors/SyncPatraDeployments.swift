import Fluent
import Foundation
import Queues
import Vapor

/// Minimal queue payload identifying the Patra resource whose deployment count should be
/// synchronized.
struct PatraResource: Codable {
  let id: UUID
}

/// Counts completed deployment runs across every card a Patra resource groups, and records their
/// sum as a single `.deployments` `Metric`.
///
/// Per-resource, unlike ``SyncPatraCatalog``'s account-level discovery — `patra_cards.resource_id`
/// is what lets a resource answer which uuids are its own, so this job pages each card's
/// `/modelcard/{uuid}/deployments` and totals them. `MegaDetector for Wildlife Detection` is the
/// live example this is built around: eleven cards, 38 deployments on one and 14 on another among
/// them, and the resource-level reading is their sum — 52 — not any single card's count.
struct SyncPatraDeployments: AsyncJob, BackoffRetrying {
  typealias Payload = PatraResource

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: PatraResource) async throws {
    await context.reportResourceSyncFailure(error, job: Self.name, resourceID: payload.id)
  }

  /// Pages every card's deployments, sums them, and writes one `.deployments` reading.
  func dequeue(_ context: QueueContext, _ payload: PatraResource) async throws {
    guard let resource = try await Resource.find(payload.id, on: context.application.db) else {
      context.entryVanished(id: payload.id, job: Self.name)
      return
    }

    // Datasheets have no deployments endpoint — Patra only runs models, never datasets — so a
    // `.dataset` resource has nothing to count. Still a successful collection: the sweep asked
    // and got a definitive (if trivial) answer, so it should rotate on the same schedule as
    // every other resource rather than being retried forever for an endpoint that will never
    // exist.
    guard resource.type != .dataset else {
      try await resource.recordSuccessfulCollection(on: context.application.db)
      return
    }

    let cards = try await PatraCard.query(on: context.application.db)
      .filter(\.$resource.$id == payload.id)
      .all()

    // No Vault lookup, no token header — deliberately, matching `SyncPatraCatalog`. An
    // authenticated caller sees Patra's PRIVATE deployment records, and this service's API and
    // dashboard are public, so sending a token here would leak exactly what those records hide.
    //
    // Fetch every card's deployments before writing anything: a failure partway through a
    // multi-card resource must not leave a metric summed from only some of its cards.
    var total = 0
    for card in cards {
      let deployments = try await PatraAPI.page(
        context, path: "/modelcard/\(card.cardUUID)/deployments", as: PatraDeployment.self)
      total += deployments.count
    }

    // Written even when `total` is 0 — the endpoint answered, and zero deployments is what it
    // said. `.deployments.allTime` is nil (see `MetricType`), so this reading is never folded;
    // Patra's count is read whole on every sweep and there is no rolling window to accumulate.
    try await Metric(
      resourceID: payload.id, reading: Double(total), type: .deployments
    ).create(on: context.application.db)

    // Anchors the backoff and the next due date on this success, last — the contract every
    // per-resource collector follows. `SyncPatraCatalog` is the one exception: it is
    // account-level and writes no metrics, so it has no per-resource cadence to anchor.
    try await resource.recordSuccessfulCollection(on: context.application.db)
  }
}
