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

    // Provenance detail is a second request per card — for a model card, `location` and
    // `training_datasheet_uuid` only live on `/modelcard/{uuid}`; for a datasheet,
    // `related_identifiers` and `alternate_identifiers` only live on `/datasheet/{uuid}` — neither
    // rides along with the list just fetched. Both detail loops hold the same "fetch everything,
    // then write" line the two list fetches above do, and now extend it across all four requests
    // rather than just the first two: a failure partway through either loop must leave the catalog
    // exactly as untouched as a failed `/datasheets` call already does. Skipping private cards here
    // matches `register` skipping them below, so an anonymous caller never spends a request on a
    // card it would discard anyway.
    var details: [String: PatraModelCardDetail] = [:]
    for card in modelCards where card.isPrivate != true {
      details[card.uuid] = try await PatraAPI.detail(context, uuid: card.uuid)
    }
    var datasheetDetails: [String: PatraDatasheetDetail] = [:]
    for sheet in datasheets where sheet.isPrivate != true {
      datasheetDetails[sheet.uuid] = try await PatraAPI.datasheetDetail(context, uuid: sheet.uuid)
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
      let patraCard = try await register(
        cardUUID: sheet.uuid, name: sheet.title, version: sheet.version,
        updatedAt: sheet.updatedAt, isPrivate: sheet.isPrivate, type: .dataset,
        accountID: accountID, context: context)
      if let patraCard, let detail = datasheetDetails[sheet.uuid] {
        try await resolveDatasheetProvenance(detail, for: patraCard, on: context.application.db)
      }
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
      if existing.resource.name != name.lowercased() {
        // Compared lowercased, not raw: `existing.resource.name` is always stored lowercase (see
        // the creation branch below), but `name` is whatever case Patra sent, so comparing
        // without lowercasing would fire this notice on every sweep for any name with an
        // uppercase letter — a false "renamed upstream" for a card that never changed at all.
        //
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
    //
    // `name.lowercased()`, matching the creation branch below and `resolveResource`'s own
    // comparison further down this file: `Resource.Create.toModel()` and `ResourceController
    // .update` both lowercase on write, so every resource this job did not itself just create
    // under raw Patra casing is stored lowercase already. Comparing against raw `name` here used
    // to match nothing once an admin edited a Patra-created resource's name (which lowercases it)
    // or once this job's own fix below started storing lowercase from the start — the next card
    // under that same name would find no match and create a duplicate resource instead of
    // attaching, silently forking that artifact's metric history in two.
    let match = try await Resource.query(on: db)
      .withDeleted()
      .filter(\.$account.$id == accountID)
      .filter(\.$name == name.lowercased())
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
      // Lowercased on creation for the same reason `Resource.Create.toModel()` lowercases: every
      // other path that writes a resource name normalizes it, and a Patra-created resource is no
      // exception — it is just as reachable from `ResourceController.update`, whose lowercasing
      // this has to match or a later admin edit desyncs the two.
      let resource = Resource(
        name: name.lowercased(),
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
    var target: (hub: Resource.IDValue?, repository: Resource.IDValue?) = (nil, nil)
    if let location = detail.aiModel?.location, let parsed = Self.parseLocation(location) {
      target = try await Self.resolveTarget(
        host: parsed.host, owner: parsed.owner, name: parsed.name, on: db)
    }
    card.$hubResource.id = target.hub
    card.$repositoryResource.id = target.repository

    try await card.save(on: db)
  }

  /// Resolves `detail`'s cross-registry provenance onto a datasheet `card` and saves it — the
  /// datasheet counterpart to `resolveProvenance` above. Same exception to `register`'s
  /// create-only rule (this is the only other place the job updates an existing row), same
  /// every-sweep re-run for the same reason: a datasheet collected before its Hugging Face
  /// counterpart is registered must resolve to nil now and link itself on a later sweep.
  ///
  /// Where a model card's detail response carries exactly one candidate location
  /// (`ai_model.location`), a datasheet's carries a whole DataCite-style list of identifiers, and
  /// most of them name a *different* artifact that merely cites this one. The live example:
  /// `yolov9-animals-AE-data` is a model card whose `related_identifiers` entry for this datasheet
  /// carries `relation_type: "IsReferencedBy"` — it trains on the dataset, it is not a mirror of
  /// it. Recording that as a same-artifact link would be exactly the false claim this feature
  /// exists to avoid, which is why `chooseDatasheetCandidate` picks at most one identifier, and
  /// only from the small set DataCite itself defines as "this same resource, elsewhere."
  private func resolveDatasheetProvenance(
    _ detail: PatraDatasheetDetail, for card: PatraCard, on db: any Database
  ) async throws {
    let candidate = Self.chooseDatasheetCandidate(detail)
    card.sourceURL = candidate?.raw

    var target: (hub: Resource.IDValue?, repository: Resource.IDValue?) = (nil, nil)
    if let parsed = candidate?.parsed {
      target = try await Self.resolveTarget(
        host: parsed.host, owner: parsed.owner, name: parsed.name, on: db)
    }
    card.$hubResource.id = target.hub
    card.$repositoryResource.id = target.repository

    try await card.save(on: db)
  }

  /// Resolves a parsed `(host, owner, name)` into whichever of the two foreign keys its host maps
  /// to — `(nil, nil)` for a host `ProvenanceTarget` cannot place, or cannot filter an account by.
  /// Factored out of `resolveProvenance` so `resolveDatasheetProvenance` consults the exact same
  /// `ProvenanceTarget`/`resolveResource` machinery once *its* identifiers have been reduced to
  /// these three parts, rather than re-deciding hub-versus-repository a second way.
  private static func resolveTarget(
    host: String, owner: String, name: String, on db: any Database
  ) async throws -> (hub: Resource.IDValue?, repository: Resource.IDValue?) {
    switch ProvenanceTarget.of(host: host) {
    case .hub(let platform):
      let id = try await resolveResource(owner: owner, name: name, platform: platform, on: db)?
        .requireID()
      return (id, nil)
    case .repository(let platform?):
      let id = try await resolveResource(owner: owner, name: name, platform: platform, on: db)?
        .requireID()
      return (nil, id)
    case .repository(nil), nil:
      // A known repository-shaped host (`gitlab.com`) with no `Platform` to filter an account
      // against — see `ProvenanceTarget`'s doc comment — or a host this job does not recognize at
      // all. Either way: no match, not "match anything."
      return (nil, nil)
    }
  }

  /// DataCite relation types this job trusts, on a `related_identifier`, as "the same artifact,
  /// elsewhere." Deliberately an allowlist, not a denylist: DataCite defines many relation types
  /// (`IsReferencedBy`, `IsDocumentedBy`, `IsSupplementTo`, `Cites`, ...) and every one of them
  /// not listed here means the identified resource merely relates to this datasheet — cites it,
  /// documents it, is derived from it — without being it. Listing the two that do mean "is it"
  /// keeps a relation type Patra adds later defaulting to rejected rather than silently accepted.
  private static let sameArtifactRelationTypes: Set<String> = ["IsVariantFormOf", "IsIdenticalTo"]

  /// One provenance identifier chosen off a datasheet's detail response by
  /// `chooseDatasheetCandidate`. `raw` always becomes `sourceURL`, whether or not `parsed`
  /// resolves to anything, so an unresolved claim stays auditable exactly like a model card's
  /// `location` does.
  private struct DatasheetCandidate {
    let raw: String
    let parsed: (host: String, owner: String, name: String)?
  }

  /// Picks at most one identifier off `detail` to treat as this datasheet's cross-registry
  /// location, in priority order.
  ///
  /// An `alternate_identifier` is checked first, and one of type `"HuggingFace"` wins outright
  /// when present: an alternate identifier is by definition the same artifact under another name
  /// (there is no relation type to second-guess, unlike a related identifier), and Patra sends
  /// this type as a bare `owner/name` pair — `"ICICLE-AI/CAN_Benchmark"` — needing no host to
  /// resolve. Only absent that does a `related_identifier` get considered, and only the first
  /// whose `relation_type` is in `sameArtifactRelationTypes`; one whose relation is a citation or
  /// documentation link is skipped entirely rather than falling back to it, so it never becomes
  /// even an unresolved `sourceURL`, let alone a link.
  private static func chooseDatasheetCandidate(_ detail: PatraDatasheetDetail)
    -> DatasheetCandidate?
  {
    if let alternate = detail.alternateIdentifiers?.first(where: {
      $0.identifierType.caseInsensitiveCompare("HuggingFace") == .orderedSame
    }) {
      let parsed = parseBareOwnerName(alternate.identifier)
        .map { (host: "huggingface.co", owner: $0.owner, name: $0.name) }
      return DatasheetCandidate(raw: alternate.identifier, parsed: parsed)
    }
    if let related = detail.relatedIdentifiers?.first(where: {
      sameArtifactRelationTypes.contains($0.relationType)
    }) {
      return DatasheetCandidate(raw: related.identifier, parsed: parseLocation(related.identifier))
    }
    return nil
  }

  /// Splits a bare `owner/name` identifier — the shape Patra sends for an `alternate_identifier`
  /// of type `HuggingFace` (`"ICICLE-AI/CAN_Benchmark"`), not a URL — into its two components,
  /// ignoring anything after them to match `parseLocation`'s own "ignore the rest" convention.
  private static func parseBareOwnerName(_ raw: String) -> (owner: String, name: String)? {
    let segments = raw.split(separator: "/", omittingEmptySubsequences: true)
    guard segments.count >= 2 else { return nil }
    return (String(segments[0]), String(segments[1]))
  }

  /// Which of the two foreign keys a location's host resolves into, and which `Platform` its
  /// owning account has to carry for that resolution to be correct rather than coincidental.
  ///
  /// `accounts` is unique on `(name, platform)`, not `name` alone (`FirstMigration.swift`), and
  /// the same organization legitimately owns accounts under one name across several platforms —
  /// the checked-in dev seed creates `icicle-ai` on `.github`, `.ghcr`, `.npm`, `.huggingface`,
  /// and `.pypi`. Resolving on name alone let a Hugging Face location match whichever `icicle-ai`
  /// resource happened to share the name, GitHub included, with no error and no log: the exact
  /// silently-wrong cross-registry link this whole feature exists to prevent. `platform` is what
  /// `resolveResource` filters accounts on, and since that pair is unique, at most one account
  /// can ever match.
  private enum ProvenanceTarget {
    case hub(Platform)
    /// `Platform?`, not `Platform`: `github.com` and `gitlab.com` share this column and the shape
    /// of a repository location — see `PatraCard.repositoryResource`'s doc comment, which is
    /// about the *column* not encoding a platform, because the UI reads it off the resolved
    /// resource's account. That is a statement about storage and display, not license for the
    /// *resolver* to match a platform that does not exist. `Platform` has no `.gitlab` case
    /// (`github, ghcr, huggingface, npm, pypi, patra`), so `gitlab.com` carries `nil` here: known
    /// as repository-shaped, with nothing to filter an account against, so it can never resolve
    /// — `sourceURL` still gets stored, exactly like any other host this job cannot place.
    case repository(Platform?)

    static func of(host: String) -> ProvenanceTarget? {
      switch host {
      case "huggingface.co": .hub(.huggingface)
      case "github.com": .repository(.github)
      case "gitlab.com": .repository(nil)
      default: nil
      }
    }
  }

  /// Splits a URL-shaped Patra identifier — a model card's `location`, or a datasheet's accepted
  /// `related_identifier` — into its host and the first two path components — owner and
  /// repo/model/dataset name — ignoring anything after them. Returns nil when the value is not a
  /// URL Insights can resolve anything from.
  ///
  /// Fails closed rather than throwing: Patra sent the literal six-character string `"test"`
  /// (quote marks included) as a `location` on one live card, and `URLComponents` simply reports
  /// no host for it, the same as for any other string with no scheme — there is no malformed-URL
  /// case that reaches here as a thrown error.
  private static func parseLocation(_ raw: String) -> (host: String, owner: String, name: String)? {
    guard let components = URLComponents(string: raw), let host = components.host else {
      return nil
    }
    var segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
    // Hugging Face datasets carry one more path segment than models do:
    // `huggingface.co/datasets/{owner}/{name}` versus a model's `huggingface.co/{owner}/{name}`.
    // Only datasheet provenance ever reaches this with a dataset-shaped URL today, but the drop
    // happens here, in the one parser both card kinds share, rather than in a second copy — a
    // model card URL with a literal `datasets` first segment is not a real shape Patra sends.
    if host.lowercased() == "huggingface.co", segments.first?.lowercased() == "datasets" {
      segments.removeFirst()
    }
    guard segments.count >= 2 else { return nil }
    return (host.lowercased(), String(segments[0]), String(segments[1]))
  }

  /// Finds a registered `Resource` whose owning account is named `owner` on `platform`, and whose
  /// own name is `name`.
  ///
  /// `platform` is required, not inferred, precisely because `(name, platform)` — not `name`
  /// alone — is what `accounts` treats as identifying: see `ProvenanceTarget`'s doc comment for
  /// the reused-name case this exists to rule out. Filtering on the pair also means at most one
  /// account can match, so this never depends on an unordered `.first()` choosing among several
  /// same-named candidates.
  ///
  /// Compared case-insensitively against already-lowercased storage — `Account.Create.toModel()`
  /// and `Resource.Create.toModel()` both lowercase on write — so lowercasing the parsed URL
  /// segments here is enough, with no need for a case-insensitive SQL comparison.
  private static func resolveResource(
    owner: String, name: String, platform: Platform, on db: any Database
  ) async throws -> Resource? {
    guard
      let account = try await Account.query(on: db)
        .filter(\.$name == owner.lowercased())
        .filter(\.$platform == platform)
        .first()
    else {
      return nil
    }

    return try await Resource.query(on: db)
      .filter(\.$account.$id == (try account.requireID()))
      .filter(\.$name == name.lowercased())
      .first()
  }
}
