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

/// Patra's HTTP surface: wire types shared by both list endpoints, and the paging loop that reads
/// them off `context.application.client`.
///
/// A namespace, not a job — `SyncPatraModelCards` and `SyncPatraDatasheets` (added in later
/// tasks) both page through this rather than building their own request loop.
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
}
