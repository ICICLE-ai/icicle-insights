import Fluent

import struct Foundation.Date
import struct Foundation.UUID

/// One Patra card — a (name, version) record with the registry's own uuid.
///
/// Not a `Release`: that means an ICICLE software release, and card versions are values like
/// `yolo11l_ep1_bs32_lr0.005_8aa95a86.pt` that would bury real release history. A card is child
/// of the `Resource` it names, not a platform of its own — `resource_id` is what lets a resource
/// answer which uuids are its own when a later sync needs to look them up.
final class PatraCard: Model, @unchecked Sendable {
  static let schema = "patra_cards"

  @ID(key: .id)
  var id: UUID?

  @Parent(key: "resource_id")
  /// Resource this card names. `type` is always `.model` today; `agent` exists for what Patra
  /// catalogs next.
  var resource: Resource

  @Field(key: "card_uuid")
  /// Patra's own identifier. The only stable key — name is not unique, and neither is
  /// (author, name, version): one pair exists twice under two uuids.
  var cardUUID: String

  @OptionalField(key: "version")
  /// The card's version string, as Patra reports it. Nil where the registry has none. Stored for
  /// completeness but deliberately unexposed — rendering "this model has 11 variants" is a later
  /// change with its own design.
  var version: String?

  @OptionalField(key: "card_updated_at")
  /// The card's `updated_at`, stored as Patra reports it rather than recomputed here.
  var cardUpdatedAt: Date?

  @OptionalField(key: "source_url")
  /// Patra's `AIModel.location`, stored raw so a failed resolution is auditable.
  var sourceURL: String?

  @OptionalParent(key: "hub_resource_id")
  /// The Hugging Face Hub resource `sourceURL` resolves to, when its host is `huggingface.co`.
  var hubResource: Resource?

  @OptionalParent(key: "repository_resource_id")
  /// The repository resource `sourceURL` resolves to, when its host is a recognized code host.
  /// Not platform-specific by name: a GitLab repository resolves into this same column, and the
  /// UI reads the platform off the linked resource rather than off the column name.
  var repositoryResource: Resource?

  @OptionalField(key: "training_datasheet_uuid")
  /// Patra's model-to-datasheet link, captured free while fetching card detail. Stored and
  /// unused today — a Patra-internal relationship rather than a cross-registry one.
  var trainingDatasheetUUID: String?

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  init() {}

  /// Creates a card associated with an existing resource.
  init(
    id: UUID? = nil,
    resourceID: Resource.IDValue,
    cardUUID: String,
    version: String? = nil,
    cardUpdatedAt: Date? = nil,
    sourceURL: String? = nil,
    hubResourceID: Resource.IDValue? = nil,
    repositoryResourceID: Resource.IDValue? = nil,
    trainingDatasheetUUID: String? = nil,
    createdAt: Date? = nil,
  ) {
    self.id = id
    $resource.id = resourceID
    self.cardUUID = cardUUID
    self.version = version
    self.cardUpdatedAt = cardUpdatedAt
    self.sourceURL = sourceURL
    $hubResource.id = hubResourceID
    $repositoryResource.id = repositoryResourceID
    self.trainingDatasheetUUID = trainingDatasheetUUID
    self.createdAt = createdAt
  }
}
