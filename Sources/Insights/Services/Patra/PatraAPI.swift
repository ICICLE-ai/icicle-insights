import Foundation
import Queues
import Vapor

/// One entry from Patra's `/modelcards` list endpoint.
///
/// A summary, not the full card: the list endpoint omits fields (author, location, metrics) that
/// only appear on `/modelcard/{id}`. Fetching those per-card is Task 5's job, not this one's.
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

/// One entry from Patra's `/datasheets` list endpoint. Same shape as ``PatraModelCard``, except
/// the registry calls the display field `title` rather than `name`.
///
/// `version` is decoded but, in practice, always nil: the live list sends no `version` key for a
/// datasheet at all, only the detail response does.
///
/// `creator` and `category` are the two descriptive fields read off the *list*, not the detail:
/// they are the datasheet's own one-line summary of each, where the detail only has DataCite's
/// longer `creators` and `subjects` arrays to fall back on. See `PatraCardDescription`.
struct PatraDatasheet: Content {
  let uuid: String
  let title: String
  let version: String?
  let isPrivate: Bool?
  let updatedAt: String?
  let creator: String?
  let category: String?

  enum CodingKeys: String, CodingKey {
    case uuid, title, version, creator, category
    case isPrivate = "is_private"
    case updatedAt = "updated_at"
  }
}

extension PatraDatasheet {
  /// Strict for the fields discovery keys on, lenient for the two descriptive ones.
  ///
  /// `uuid`, `title`, `is_private`, and `updated_at` keep exactly the strictness synthesized
  /// decoding gave them before `creator` and `category` existed: a list entry that cannot say
  /// which card it is, or whether it is private, has to fail loudly rather than register as a
  /// guess. The descriptive pair only feeds display, so a type drift there costs that value, not
  /// the sweep — see `lenientString(forKey:)`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uuid = try container.decode(String.self, forKey: .uuid)
    title = try container.decode(String.self, forKey: .title)
    version = try container.decodeIfPresent(String.self, forKey: .version)
    isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    creator = container.lenientString(forKey: .creator)
    category = container.lenientString(forKey: .category)
  }
}

/// One entry from a model card's `/deployments` endpoint.
///
/// Only the count is used, and an empty Decodable accepts any object — so a new field or a
/// changed type upstream cannot break the metric.
struct PatraDeployment: Content {}

/// The AI model Patra imported, nested inside `PatraModelCardDetail`.
///
/// `location` is Patra's own record of where it pulled the model from, and it is optional in
/// both senses: the object can be present with a nil location, and on one live card the value is
/// not a URL at all (the literal string `"test"`, quote marks included). Decoding never rejects
/// that; only the URL parser downstream has to survive it.
///
/// The rest are descriptive, read into `PatraCardDescription`: `description` and `owner` as
/// fallbacks for the card's own `short_description` and `author`, and `license`, `framework`,
/// `model_type`, and `test_accuracy` as the only source of each.
struct PatraAIModel: Content {
  let location: String?
  let description: String?
  let owner: String?
  let license: String?
  let framework: String?
  let modelType: String?
  let testAccuracy: Double?

  enum CodingKeys: String, CodingKey {
    case location, description, owner, license, framework
    case modelType = "model_type"
    case testAccuracy = "test_accuracy"
  }
}

extension PatraAIModel {
  /// Strict for `location`, lenient for everything descriptive.
  ///
  /// `location` keeps the strict decode it always had, and on purpose: it feeds provenance, and
  /// a lenient nil there would not just drop a value, it would *clear* a resolved hub or
  /// repository link on the next save. A drift in `location` should fail the sweep and be seen.
  /// The descriptive fields only feed display, so theirs cost one value instead.
  ///
  /// `test_accuracy` is live as a JSON number between 0 and 1, but is read from a numeric string
  /// too — see `lenientDouble(forKey:)`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    location = try container.decodeIfPresent(String.self, forKey: .location)
    description = container.lenientString(forKey: .description)
    owner = container.lenientString(forKey: .owner)
    license = container.lenientString(forKey: .license)
    framework = container.lenientString(forKey: .framework)
    modelType = container.lenientString(forKey: .modelType)
    testAccuracy = container.lenientDouble(forKey: .testAccuracy)
  }
}

/// Full detail for one Patra model card, from `GET /modelcard/{uuid}`.
///
/// Not `PatraModelCard`, the `/modelcards` list summary: `ai_model` (and so `location`) and
/// `training_datasheet_uuid` only appear on this detail response, which is why resolving
/// provenance costs one extra request per card rather than riding along with the list fetch.
///
/// The descriptive fields are read here too rather than off the list, even where the list
/// repeats one (`short_description`, `author`, `categories`, `is_gated`): the detail is a
/// superset, and one source per card keeps the fallback order in `PatraCardDescription` in one
/// place instead of splitting it across two responses.
struct PatraModelCardDetail: Content {
  let aiModel: PatraAIModel?
  let trainingDatasheetUUID: String?
  let shortDescription: String?
  let fullDescription: String?
  let author: String?
  let categories: String?
  let inputType: String?
  let keywords: String?
  let isGated: Bool?

  enum CodingKeys: String, CodingKey {
    case aiModel = "ai_model"
    case trainingDatasheetUUID = "training_datasheet_uuid"
    case shortDescription = "short_description"
    case fullDescription = "full_description"
    case author, categories, keywords
    case inputType = "input_type"
    case isGated = "is_gated"
  }
}

extension PatraModelCardDetail {
  /// Strict for provenance (`ai_model`'s shape, `training_datasheet_uuid`), exactly as synthesized
  /// decoding was before the descriptive fields; lenient for the descriptive ones.
  ///
  /// `keywords` is a comma-separated string on the live API, null on six of its 38 cards, and
  /// read from a JSON array of strings too, joined with `", "` so it lands in the same stored
  /// shape — see `lenientKeywords(forKey:)`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    aiModel = try container.decodeIfPresent(PatraAIModel.self, forKey: .aiModel)
    trainingDatasheetUUID = try container.decodeIfPresent(
      String.self, forKey: .trainingDatasheetUUID)
    shortDescription = container.lenientString(forKey: .shortDescription)
    fullDescription = container.lenientString(forKey: .fullDescription)
    author = container.lenientString(forKey: .author)
    categories = container.lenientString(forKey: .categories)
    inputType = container.lenientString(forKey: .inputType)
    keywords = container.lenientKeywords(forKey: .keywords)
    isGated = container.lenientBool(forKey: .isGated)
  }
}

/// One DataCite-style related identifier from a datasheet's detail response.
///
/// `related_identifiers` names *other* artifacts, not necessarily this one under another name —
/// `relation_type` is what tells them apart. A card whose relation is `IsReferencedBy` or
/// `IsDocumentedBy` merely cites this datasheet (the live example: a model trained on it); one
/// whose relation is `IsVariantFormOf` or `IsIdenticalTo` names the same artifact elsewhere. See
/// `SyncPatraCatalog.resolveDatasheetProvenance` for which relations this job trusts.
struct PatraRelatedIdentifier: Content {
  let identifier: String
  let relationType: String

  enum CodingKeys: String, CodingKey {
    case identifier = "related_identifier"
    case relationType = "relation_type"
  }
}

/// One DataCite-style alternate identifier from a datasheet's detail response.
///
/// Unlike `PatraRelatedIdentifier`, an alternate identifier is *by definition* the same artifact
/// under a different name — there is no relation type to check. `identifierType` says what kind
/// of identifier it is; only `"HuggingFace"` (a bare `owner/name` pair, not a URL) is one this job
/// knows how to resolve. Others (`"URL"`, `"DOI"`, ...) decode without error but resolve nothing.
struct PatraAlternateIdentifier: Content {
  let identifier: String
  let identifierType: String

  enum CodingKeys: String, CodingKey {
    case identifier = "alternate_identifier"
    case identifierType = "alternate_identifier_type"
  }
}

/// One entry of a datasheet's DataCite `creators` array. Only the name is read, as the fallback
/// author when the list entry carries no `creator`.
struct PatraCreator: Content {
  let creatorName: String?

  enum CodingKeys: String, CodingKey {
    case creatorName = "creator_name"
  }

  init(from decoder: any Decoder) throws {
    creatorName = try decoder.container(keyedBy: CodingKeys.self)
      .lenientString(forKey: .creatorName)
  }
}

/// One entry of a datasheet's DataCite `subjects` array. Only the subject is read, as the
/// fallback category when the list entry carries no `category`.
struct PatraSubject: Content {
  let subject: String?

  init(from decoder: any Decoder) throws {
    subject = try decoder.container(keyedBy: CodingKeys.self).lenientString(forKey: .subject)
  }
}

/// One entry of a datasheet's DataCite `rights_list`. Only the human-readable `rights` is read,
/// not `rights_identifier`: the SPDX identifier is missing on some live entries (`Unsplash
/// License` has none), and a model card's `license` is the same kind of display name.
struct PatraRights: Content {
  let rights: String?

  init(from decoder: any Decoder) throws {
    rights = try decoder.container(keyedBy: CodingKeys.self).lenientString(forKey: .rights)
  }
}

/// One entry of a datasheet's DataCite `descriptions` array.
///
/// `description_type` is not read. On every live datasheet the first entry is the `Abstract`,
/// and the second, where there is one, is `TechnicalInfo`, so taking the first already shows the
/// abstract without a type filter that a datasheet with untyped descriptions would fail.
struct PatraDescriptionEntry: Content {
  let description: String?

  init(from decoder: any Decoder) throws {
    description = try decoder.container(keyedBy: CodingKeys.self)
      .lenientString(forKey: .description)
  }
}

/// Full detail for one Patra datasheet, from `GET /datasheet/{uuid}`.
///
/// Not `PatraDatasheet`, the `/datasheets` list summary: `related_identifiers` and
/// `alternate_identifiers` only appear here, the same relationship `PatraModelCardDetail` has to
/// `PatraModelCard`. Both arrays are optional, not just possibly-empty — a live datasheet can omit
/// `alternate_identifiers` outright rather than sending `[]`.
///
/// The descriptive fields are DataCite's: arrays of objects for creators, subjects, rights, and
/// descriptions, of which `PatraCardDescription` reads the first usable entry, and plain values
/// for `size`, `format`, and `publication_year`.
struct PatraDatasheetDetail: Content {
  let relatedIdentifiers: [PatraRelatedIdentifier]?
  let alternateIdentifiers: [PatraAlternateIdentifier]?
  let descriptions: [PatraDescriptionEntry]?
  let creators: [PatraCreator]?
  let subjects: [PatraSubject]?
  let rightsList: [PatraRights]?
  let size: String?
  let format: String?
  let publicationYear: Int?

  enum CodingKeys: String, CodingKey {
    case relatedIdentifiers = "related_identifiers"
    case alternateIdentifiers = "alternate_identifiers"
    case descriptions, creators, subjects, size, format
    case rightsList = "rights_list"
    case publicationYear = "publication_year"
  }
}

extension PatraDatasheetDetail {
  /// Strict for the two identifier arrays provenance reads, exactly as synthesized decoding was
  /// before the descriptive fields; lenient for everything descriptive.
  ///
  /// `publication_year` is a JSON number on the live API but is read from a numeric string too,
  /// since DataCite itself defines the year as a string — see `lenientInt(forKey:)`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    relatedIdentifiers = try container.decodeIfPresent(
      [PatraRelatedIdentifier].self, forKey: .relatedIdentifiers)
    alternateIdentifiers = try container.decodeIfPresent(
      [PatraAlternateIdentifier].self, forKey: .alternateIdentifiers)
    descriptions = container.lenientArray(of: PatraDescriptionEntry.self, forKey: .descriptions)
    creators = container.lenientArray(of: PatraCreator.self, forKey: .creators)
    subjects = container.lenientArray(of: PatraSubject.self, forKey: .subjects)
    rightsList = container.lenientArray(of: PatraRights.self, forKey: .rightsList)
    size = container.lenientString(forKey: .size)
    format = container.lenientString(forKey: .format)
    publicationYear = container.lenientInt(forKey: .publicationYear)
  }
}

/// The descriptive half of one Patra card, reduced from its list entry and detail response to the
/// thirteen values `patra_cards` stores.
///
/// A value type between the wire and the row, rather than assignments straight onto `PatraCard`,
/// so the fallback order for each field is stated once and testable without a database. Both
/// initializers produce every field, nil where the card kind has no such thing (a datasheet has no
/// `framework`, a model card no `size`), and `apply(to:)` writes all thirteen: a card never keeps
/// a stale value Patra has since cleared.
///
/// Every string is already trimmed and non-empty by the time it gets here — the lenient decoders
/// see to that — so a fallback chain skips an empty `short_description` (one live card sends `""`)
/// rather than stopping at it.
struct PatraCardDescription: Equatable, Sendable {
  var description: String?
  var author: String?
  var category: String?
  var license: String?
  var framework: String?
  var modelType: String?
  var inputType: String?
  var accuracy: Double?
  var keywords: String?
  var isGated: Bool?
  var size: String?
  var format: String?
  var publicationYear: Int?
}

// In an extension so the struct keeps its synthesized memberwise initializer, every field
// defaulting to nil, which is what a test states an expected description with.
extension PatraCardDescription {
  /// A model card's description, from its detail response alone.
  ///
  /// `short_description` first because it is what the card says about itself in one line, which
  /// is what a gallery tile has room for. `ai_model.description` next, then `full_description`
  /// last: it is body text rather than a summary, and runs to about 900 characters on the live
  /// API. `author` falls back to `ai_model.owner`, which on the live API is often the organization
  /// behind the model (`Ultralytics`, `Google`) rather than the person who filed the card.
  init(modelCard detail: PatraModelCardDetail) {
    description =
      detail.shortDescription ?? detail.aiModel?.description ?? detail.fullDescription
    author = detail.author ?? detail.aiModel?.owner
    category = detail.categories
    license = detail.aiModel?.license
    framework = detail.aiModel?.framework
    modelType = detail.aiModel?.modelType
    inputType = detail.inputType
    accuracy = detail.aiModel?.testAccuracy
    keywords = detail.keywords
    isGated = detail.isGated
  }

  /// A datasheet's description, from its list entry and its detail response together.
  ///
  /// `creator` and `category` come from the list first: they are the datasheet's own one-line
  /// answer, where DataCite's `creators` and `subjects` are lists whose first entry is only the
  /// best available guess at one. Each array contributes its first entry that has a usable value,
  /// not merely its first entry, so one blank element does not hide a good one behind it.
  init(datasheet sheet: PatraDatasheet, detail: PatraDatasheetDetail) {
    description = detail.descriptions?.lazy.compactMap(\.description).first
    author = sheet.creator ?? detail.creators?.lazy.compactMap(\.creatorName).first
    category = sheet.category ?? detail.subjects?.lazy.compactMap(\.subject).first
    license = detail.rightsList?.lazy.compactMap(\.rights).first
    size = detail.size
    format = detail.format
    publicationYear = detail.publicationYear
  }

  /// Writes all thirteen values onto `card` without saving it. The caller saves, so a sweep can
  /// write a card's description and its provenance in one `UPDATE` — see
  /// `SyncPatraCatalog.dequeue`.
  func apply(to card: PatraCard) {
    card.cardDescription = description
    card.author = author
    card.category = category
    card.license = license
    card.framework = framework
    card.modelType = modelType
    card.inputType = inputType
    card.accuracy = accuracy
    card.keywords = keywords
    card.isGated = isGated
    card.size = size
    card.format = format
    card.publicationYear = publicationYear
  }
}

// MARK: - Lenient decoding

/// Decoders for Patra's descriptive fields that return nil instead of throwing.
///
/// Patra's schema is loosely held: `keywords` is a string on most cards and null on others, and
/// nothing upstream stops a field changing type. A strict `decode` would turn one such drift into
/// `decodingFailed` for the whole detail response, and because `SyncPatraCatalog` fetches
/// everything before writing anything, into a sweep that registers nothing — discovery and
/// provenance included — over a value that only ever feeds display. These cost that one value
/// instead.
///
/// `fileprivate`: this leniency is right for display fields and wrong for keys. Nothing that
/// identifies a card, decides whether it is private, or feeds provenance should reach for it.
extension KeyedDecodingContainer {
  /// A string trimmed of surrounding whitespace, or nil for null, absent, empty, all-whitespace,
  /// or not a string at all.
  fileprivate func lenientString(forKey key: Key) -> String? {
    (try? decodeIfPresent(String.self, forKey: key)).flatMap(PatraText.clean)
  }

  /// A finite number, from a JSON number or a numeric string. Non-finite values are refused, not
  /// stored: `JSONEncoder` throws on NaN or infinity by default, so one stored `"nan"` would turn
  /// every `GET /api/resources` into a 500.
  fileprivate func lenientDouble(forKey key: Key) -> Double? {
    let value =
      (try? decodeIfPresent(Double.self, forKey: key))
      ?? lenientString(forKey: key).flatMap(Double.init)
    return value.flatMap { $0.isFinite ? $0 : nil }
  }

  /// An integer, from a JSON integer or a string holding one.
  fileprivate func lenientInt(forKey key: Key) -> Int? {
    (try? decodeIfPresent(Int.self, forKey: key)) ?? lenientString(forKey: key).flatMap(Int.init)
  }

  /// A JSON boolean, or nil. Strings such as `"true"` are not interpreted: a flag is a flag, and
  /// guessing at one is worse than not knowing.
  fileprivate func lenientBool(forKey key: Key) -> Bool? {
    try? decodeIfPresent(Bool.self, forKey: key)
  }

  /// Patra's keywords as the one comma-separated string `patra_cards.keywords` stores: the string
  /// itself when Patra sends one, or an array of strings joined with `", "` when it sends that.
  fileprivate func lenientKeywords(forKey key: Key) -> String? {
    if let string = lenientString(forKey: key) { return string }
    guard let list = try? decodeIfPresent([String].self, forKey: key) else { return nil }
    return PatraText.clean(list.compactMap(PatraText.clean).joined(separator: ", "))
  }

  /// An array whose elements decode one by one, dropping any that fail, or nil when the value is
  /// not an array at all. One malformed DataCite entry costs that entry, not its siblings.
  fileprivate func lenientArray<Element: Decodable>(
    of: Element.Type, forKey key: Key
  ) -> [Element]? {
    (try? decodeIfPresent([Lenient<Element>].self, forKey: key))?.compactMap(\.value)
  }
}

/// Decodes one element, or records nil where it could not, so an array of them never fails as a
/// whole. Used only by `lenientArray(of:forKey:)`.
private struct Lenient<Wrapped: Decodable>: Decodable {
  let value: Wrapped?

  init(from decoder: any Decoder) throws {
    value = try? Wrapped(from: decoder)
  }
}

/// Text normalization shared by every lenient string.
enum PatraText {
  /// Trims surrounding whitespace and newlines, and turns what is left into nil when empty. An
  /// empty string is not a value to show: one live card's `short_description` is `""`, and
  /// keeping it would both display a blank and stop the fallback to `ai_model.description`.
  static func clean(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Patra's HTTP surface: wire types shared by both list endpoints, and the paging loop that reads
/// them off `context.application.client`.
///
/// A namespace, not a job — `SyncPatraCatalog` (added in a later task) pages both endpoints
/// through this rather than building its own request loop.
enum PatraAPI {
  /// Patra has no environment-specific deployment today, unlike Tapis's per-tenant hosts — so
  /// this is a constant, not a config knob, matching `SyncHuggingFaceHubStats`'s hardcoded
  /// `baseUrl` rather than `TapisConfig`'s `TAPIS_BASE_URL`.
  static let baseURL = "https://patrabackend.pods.icicleai.tapis.io"

  /// `.withFractionalSeconds` is required: Patra sends microseconds, and the formatter returns
  /// nil for the whole string without it rather than truncating.
  ///
  /// `nonisolated(unsafe)`: `ISO8601DateFormatter` is not `Sendable`, but this instance is
  /// configured once here and never mutated again — every later use is a read, which is safe to
  /// share across the concurrent collectors that will call ``string(from:)``.
  nonisolated(unsafe) static let timestamps: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  /// Pages until a short page returns. `limit` is capped at 100 server-side; anything larger is
  /// a 422, so this asks for exactly the maximum.
  ///
  /// This is the defect most likely to ship working and break later: `/modelcards` returns 37
  /// today against a default page of 50, and a single-page fetch would look correct until the
  /// registry crossed that boundary. MegaDetector `6b-yolov9c` is already at 38 deployments.
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
        throw JobError.apiRequestFailed(url: url, response: response)
      }
      let batch: [T]
      do {
        batch = try response.content.decode([T].self)
      } catch {
        throw JobError.decodingFailed(url: url.string, underlying: error)
      }
      all += batch
      if batch.count < limit { return all }
      skip += limit
    }
  }

  /// Fetches one model card's full detail — the only source of `location` and
  /// `training_datasheet_uuid`, both absent from `/modelcards`. Unpaginated: this is a single
  /// object, not a list.
  static func detail(_ context: QueueContext, uuid: String) async throws -> PatraModelCardDetail {
    let url = URI(string: "\(baseURL)/modelcard/\(uuid)")
    let response = try await context.application.client.get(url)
    guard response.status == .ok else {
      throw JobError.apiRequestFailed(url: url, response: response)
    }
    do {
      return try response.content.decode(PatraModelCardDetail.self)
    } catch {
      throw JobError.decodingFailed(url: url.string, underlying: error)
    }
  }

  /// Fetches one datasheet's full detail — the only source of `related_identifiers` and
  /// `alternate_identifiers`, both absent from `/datasheets`. Unpaginated, matching `detail(_:uuid:)`
  /// above; the mirror-image request that makes datasheet provenance resolvable the same way model
  /// card provenance already is.
  static func datasheetDetail(
    _ context: QueueContext, uuid: String
  ) async throws -> PatraDatasheetDetail {
    let url = URI(string: "\(baseURL)/datasheet/\(uuid)")
    let response = try await context.application.client.get(url)
    guard response.status == .ok else {
      throw JobError.apiRequestFailed(url: url, response: response)
    }
    do {
      return try response.content.decode(PatraDatasheetDetail.self)
    } catch {
      throw JobError.decodingFailed(url: url.string, underlying: error)
    }
  }
}
