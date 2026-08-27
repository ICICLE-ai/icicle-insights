import Fluent
import Foundation
import Queues
import Vapor

/// Minimal queue payload identifying the Patra account whose catalog should be synchronized.
struct PatraAccount: Codable {
  let id: UUID
}

/// Discovers Patra's model and datasheet catalog, registering every card as a `Resource` and a
/// child `PatraCard`.
///
/// Account-level like `SyncGitHubOrgStats`, but where that job updates one field on an existing
/// row, this one creates rows — because a Patra "model card" is a (name, version) pair, not a
/// distinct model. `MegaDetector for Wildlife Detection` alone is eleven cards under one name,
/// ten versions, four authors; grouping by name is what turns 37 model cards into the 23 models
/// they actually are. Counting usage per resource (`deployments`) is a separate, resource-level
/// job added later; this one only discovers what exists.
struct SyncPatraCatalog: AsyncJob, BackoffRetrying {
  typealias Payload = PatraAccount

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: PatraAccount) async throws {
    await context.reportAccountSyncFailure(error, job: Self.name, accountID: payload.id)
  }

  /// Pages both catalogs and folds each entry into `Resource`/`PatraCard` rows.
  func dequeue(_ context: QueueContext, _ payload: PatraAccount) async throws {
    guard let account = try await Account.find(payload.id, on: context.application.db) else {
      context.entryVanished(id: payload.id, job: Self.name)
      return
    }
    let accountID = try account.requireID()

    // No Vault lookup, no token header — deliberately, and the first collector here where that
    // is true. Patra's list endpoints answer PRIVATE records to a JWT-bearing caller, and this
    // service's API and dashboard are public, so sending a token would leak exactly what
    // `is_private` exists to hide. Filtering `is_private` per card in `register` below is what
    // an anonymous caller needs instead.
    //
    // Fetch everything, THEN write everything — across both catalogs, not just within one.
    // `PatraAPI.page` already fetches every page of a single endpoint before returning, so within
    // `/modelcards` this held for free; but writing model cards immediately and only afterward
    // requesting `/datasheets` reopened the same hole one level up. A `/datasheets` failure after
    // the model half had already landed left exactly the half-registry this convention exists to
    // prevent — model resources persisted, zero datasets, until a backoff-delayed retry. Both
    // requests now complete before either `register` loop runs a single write.
    let modelCards = try await PatraAPI.page(
      context, path: "/modelcards", as: PatraModelCard.self)
    let datasheets = try await PatraAPI.page(
      context, path: "/datasheets", as: PatraDatasheet.self)

    for card in modelCards {
      try await register(
        cardUUID: card.uuid, name: card.name, version: card.version, updatedAt: card.updatedAt,
        isPrivate: card.isPrivate, type: .model, accountID: accountID, context: context)
    }
    for sheet in datasheets {
      try await register(
        cardUUID: sheet.uuid, name: sheet.title, version: sheet.version,
        updatedAt: sheet.updatedAt, isPrivate: sheet.isPrivate, type: .dataset,
        accountID: accountID, context: context)
    }

    // Deliberately no `resource.recordSuccessfulCollection(on:)` call, even though
    // `add-a-collector.md` asks for the opposite. That method anchors one resource's own
    // collection cadence and backoff; this sweep is account-level and writes no metrics, so
    // calling it per touched resource would book a collection the dispatcher then skips —
    // advancing a due date for a sweep that never happened.
  }

  /// Applies the discovery rules for one catalog entry — a model card or a datasheet, the two
  /// share a shape once `name`/`title` is unified by the caller — in priority order: a known
  /// `card_uuid` always short-circuits, a private card is skipped before any resource is
  /// touched, and a soft-deleted resource is never resurrected by a new card arriving under its
  /// old name.
  private func register(
    cardUUID: String,
    name: String,
    version: String?,
    updatedAt: String?,
    isPrivate: Bool?,
    type: ResourceType,
    accountID: UUID,
    context: QueueContext
  ) async throws {
    let db = context.application.db

    // `card_uuid` is the only stable key — name collides for seven (author, name) pairs, and
    // even (author, name, version) collides once — so a known uuid is the whole idempotency
    // guarantee and wins over everything else below, including a name that has since changed.
    //
    // `withDeleted: true`: the resource this card names may have been soft-deleted since the
    // card was recorded. Eager-loading a deleted parent without that flag throws
    // `missingParentError` instead of returning it, which would fail every re-run of a sync that
    // has ever touched a since-deleted resource — including the idempotent re-run this check
    // exists to make safe.
    if let existing = try await PatraCard.query(on: db)
      .filter(\.$cardUUID == cardUUID)
      .with(\.$resource, withDeleted: true)
      .first()
    {
      if existing.resource.name != name {
        // Not applied, only recorded: a resource can already carry cards from other authors
        // under this name (name is not unique), so renaming it because one card changed
        // upstream would be presumptuous, and it would orphan metric history against a name
        // nobody recognizes. An admin decides by hand; this just makes the drift visible.
        context.logger.notice(
          "Patra card renamed upstream; resource name kept as-is",
          metadata: [
            "card_uuid": .string(cardUUID),
            "resource_name": .string(existing.resource.name),
            "incoming_name": .string(name),
          ]
        )
      }
      return
    }

    guard isPrivate != true else {
      // Skip entirely — no resource, no card. A card the registry later makes public is
      // indistinguishable from a new card on some later sweep, which is the correct outcome.
      return
    }

    // `.withDeleted()`: a name match has to see soft-deleted resources too, or a resource an
    // admin deleted looks "unseen" here and the next card under that name collides with it on
    // `resources`' (name, account_id, type) unique index instead of being skipped cleanly below.
    let match = try await Resource.query(on: db)
      .withDeleted()
      .filter(\.$account.$id == accountID)
      .filter(\.$name == name)
      .filter(\.$type == type)
      .first()

    let resourceID: Resource.IDValue
    if let match {
      guard match.deletedAt == nil else {
        // An admin deletion means "stop tracking this" — a new card arriving under the same
        // name does not undo that decision.
        return
      }
      resourceID = try match.requireID()
    } else {
      let resource = Resource(
        name: name,
        type: type,
        accountID: accountID,
        // Due now, not nil: `CollectDueResources` filters on `nextCollectionAt <= now` and skips
        // a nil due date outright, so a freshly discovered resource needs an explicit date to
        // enter the very next sweep rather than sitting invisible until some unrelated write
        // gives it one.
        nextCollectionAt: Date(),
      )
      try await resource.create(on: db)
      resourceID = try resource.requireID()
    }

    try await PatraCard(
      resourceID: resourceID,
      cardUUID: cardUUID,
      version: version,
      cardUpdatedAt: updatedAt.flatMap { PatraAPI.timestamps.date(from: $0) },
    ).create(on: db)
  }
}
