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

    // Provenance detail is a second request per model card — `location` and
    // `training_datasheet_uuid` only live on `/modelcard/{uuid}`, not the list just fetched —
    // and it holds the same "fetch everything, then write" line the two list fetches above do.
    // A failure partway through this loop must leave the catalog exactly as untouched as a
    // failed `/datasheets` call already does; skipping private cards here matches `register`
    // skipping them below, so an anonymous caller never spends a request on a card it would
    // discard anyway.
    var details: [String: PatraModelCardDetail] = [:]
    for card in modelCards where card.isPrivate != true {
      details[card.uuid] = try await PatraAPI.detail(context, uuid: card.uuid)
    }

    for card in modelCards {
      let patraCard = try await register(
        cardUUID: card.uuid, name: card.name, version: card.version, updatedAt: card.updatedAt,
        isPrivate: card.isPrivate, type: .model, accountID: accountID, context: context)
      if let patraCard, let detail = details[card.uuid] {
        try await resolveProvenance(detail, for: patraCard, on: context.application.db)
      }
    }
    for sheet in datasheets {
      _ = try await register(
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
  ///
  /// Returns the card that now exists under `cardUUID`, or nil when this entry was skipped
  /// (private, or its resource is soft-deleted) and so has no row for a caller to act on further.
  /// `dequeue` uses the return value to attach this sweep's provenance resolution to the right
  /// row, whether that row was just created here or already existed from an earlier sweep.
  @discardableResult
  private func register(
    cardUUID: String,
    name: String,
    version: String?,
    updatedAt: String?,
    isPrivate: Bool?,
    type: ResourceType,
    accountID: UUID,
    context: QueueContext
  ) async throws -> PatraCard? {
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
      return existing
    }

    guard isPrivate != true else {
      // Skip entirely — no resource, no card. A card the registry later makes public is
      // indistinguishable from a new card on some later sweep, which is the correct outcome.
      return nil
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
        return nil
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

    let card = PatraCard(
      resourceID: resourceID,
      cardUUID: cardUUID,
      version: version,
      cardUpdatedAt: updatedAt.flatMap { PatraAPI.timestamps.date(from: $0) },
    )
    try await card.create(on: db)
    return card
  }

  /// Resolves `detail`'s cross-registry location onto `card` and saves it.
  ///
  /// **This is the one place `SyncPatraCatalog` updates an existing row.** Everything in
  /// `register` above is create-only by design — a card renamed upstream is logged, not applied,
  /// because a resource can already group cards from other authors and there is no single
  /// correct name to reconcile toward. Provenance is different: it only ever fills a null link
  /// or corrects one to a resource that has since moved, and it never touches `name`, `version`,
  /// or a metric, so overwriting it on every sweep is safe in a way overwriting the name would
  /// not be. That is also why it has to run every sweep rather than only at creation — a card
  /// collected before its Hugging Face counterpart is registered must resolve to nil on this
  /// pass and link itself on a later one, once that counterpart exists.
  private func resolveProvenance(
    _ detail: PatraModelCardDetail, for card: PatraCard, on db: any Database
  ) async throws {
    card.sourceURL = detail.aiModel?.location
    card.trainingDatasheetUUID = detail.trainingDatasheetUUID

    // Recomputed from scratch rather than only filled when nil: a stale link has to be able to
    // clear itself too, not just gain one, if Patra's own record of the location moves on.
    var hubResourceID: Resource.IDValue?
    var repositoryResourceID: Resource.IDValue?
    if let location = detail.aiModel?.location, let parsed = Self.parseLocation(location) {
      if Self.hubHosts.contains(parsed.host) {
        hubResourceID = try await Self.resolveResource(
          owner: parsed.owner, name: parsed.name, on: db
        )?.requireID()
      } else if Self.repositoryHosts.contains(parsed.host) {
        repositoryResourceID = try await Self.resolveResource(
          owner: parsed.owner, name: parsed.name, on: db
        )?.requireID()
      }
    }
    card.$hubResource.id = hubResourceID
    card.$repositoryResource.id = repositoryResourceID

    try await card.save(on: db)
  }

  /// Hosts whose location resolves into `hubResource`.
  private static let hubHosts: Set<String> = ["huggingface.co"]

  /// Hosts whose location resolves into `repositoryResource`. `gitlab.com` shares the shape with
  /// `github.com` and the same column — see `PatraCard.repositoryResource`'s doc comment — even
  /// though nothing in `Platform` names a GitLab account today, so a GitLab location is parsed
  /// the same way and simply never finds a match.
  private static let repositoryHosts: Set<String> = ["github.com", "gitlab.com"]

  /// Splits a Patra `location` value into its host and the first two path components — owner and
  /// repo/model name — ignoring anything after them. Returns nil when the value is not a URL
  /// Insights can resolve anything from.
  ///
  /// Fails closed rather than throwing: Patra sent the literal six-character string `"test"`
  /// (quote marks included) as a `location` on one live card, and `URLComponents` simply reports
  /// no host for it, the same as for any other string with no scheme — there is no malformed-URL
  /// case that reaches here as a thrown error.
  private static func parseLocation(_ raw: String) -> (host: String, owner: String, name: String)? {
    guard let components = URLComponents(string: raw), let host = components.host else {
      return nil
    }
    let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
    guard segments.count >= 2 else { return nil }
    return (host.lowercased(), String(segments[0]), String(segments[1]))
  }

  /// Finds a registered `Resource` whose owning account is named `owner` and whose own name is
  /// `name`.
  ///
  /// Compared case-insensitively against already-lowercased storage — `Account.Create.toModel()`
  /// and `Resource.Create.toModel()` both lowercase on write — so lowercasing the parsed URL
  /// segments here is enough, with no need for a case-insensitive SQL comparison.
  ///
  /// Deliberately platform-agnostic: nothing here requires the owning account's `platform` to
  /// match the URL's host that chose which column to resolve into. The UI reads the actual
  /// platform off the resolved resource's own account, not off which of `hubResource` /
  /// `repositoryResource` it landed in.
  private static func resolveResource(
    owner: String, name: String, on db: any Database
  ) async throws -> Resource? {
    let accounts = try await Account.query(on: db)
      .filter(\.$name == owner.lowercased())
      .all()
    let accountIDs = try accounts.map { try $0.requireID() }
    guard !accountIDs.isEmpty else { return nil }

    return try await Resource.query(on: db)
      .filter(\.$account.$id ~~ accountIDs)
      .filter(\.$name == name.lowercased())
      .first()
  }
}
