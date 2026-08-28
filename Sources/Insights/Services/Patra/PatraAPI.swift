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
struct PatraDatasheet: Content {
  let uuid: String
  let title: String
  let version: String?
  let isPrivate: Bool?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case uuid, title, version
    case isPrivate = "is_private"
    case updatedAt = "updated_at"
  }
}

/// One entry from a model card's `/deployments` endpoint.
///
/// Only the count is used, and an empty Decodable accepts any object — so a new field or a
/// changed type upstream cannot break the metric.
struct PatraDeployment: Content {}

/// The AI model Patra imported, nested inside `PatraModelCardDetail`.
///
/// `location` is the only field read here — Patra's own record of where it pulled the model
/// from — and it is optional in both senses: the object can be present with a nil location, and
/// on one live card the value is not a URL at all (the literal string `"test"`, quote marks
/// included). Decoding never rejects that; only the URL parser downstream has to survive it.
struct PatraAIModel: Content {
  let location: String?
}

/// Full detail for one Patra model card, from `GET /modelcard/{uuid}`.
///
/// Not `PatraModelCard`, the `/modelcards` list summary: `ai_model` (and so `location`) and
/// `training_datasheet_uuid` only appear on this detail response, which is why resolving
/// provenance costs one extra request per card rather than riding along with the list fetch.
struct PatraModelCardDetail: Content {
  let aiModel: PatraAIModel?
  let trainingDatasheetUUID: String?

  enum CodingKeys: String, CodingKey {
    case aiModel = "ai_model"
    case trainingDatasheetUUID = "training_datasheet_uuid"
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

/// Full detail for one Patra datasheet, from `GET /datasheet/{uuid}`.
///
/// Not `PatraDatasheet`, the `/datasheets` list summary: `related_identifiers` and
/// `alternate_identifiers` only appear here, the same relationship `PatraModelCardDetail` has to
/// `PatraModelCard`. Both arrays are optional, not just possibly-empty — a live datasheet can omit
/// `alternate_identifiers` outright rather than sending `[]`.
struct PatraDatasheetDetail: Content {
  let relatedIdentifiers: [PatraRelatedIdentifier]?
  let alternateIdentifiers: [PatraAlternateIdentifier]?

  enum CodingKeys: String, CodingKey {
    case relatedIdentifiers = "related_identifiers"
    case alternateIdentifiers = "alternate_identifiers"
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
