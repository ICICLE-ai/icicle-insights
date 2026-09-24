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

  // MARK: Descriptive fields
  //
  // What the card says about its artifact, for display only: nothing here keys, groups, or links
  // anything. `SyncPatraCatalog` overwrites all of them from Patra on every sweep, existing cards
  // included, so an edit upstream reaches this row on the next sweep and a value Patra clears is
  // cleared here too. Each is nil wherever Patra sends null, an empty string, or a value of a
  // type the decoder does not accept — see `PatraCardDescription` for where each one comes from.

  @OptionalField(key: "description")
  /// A short account of the artifact. `cardDescription` rather than `description`: every Fluent
  /// model is `CustomStringConvertible` through `AnyModel`, so a property named `description`
  /// would collide with the string Fluent prints the row as.
  var cardDescription: String?

  @OptionalField(key: "author")
  /// Who made the card: the model card's author or the datasheet's creator.
  var author: String?

  @OptionalField(key: "category")
  /// Patra's free-text category, such as `classification` or `Camera trap`. Not an enum: Patra
  /// does not constrain it, and the live catalog already spells one category three ways.
  var category: String?

  @OptionalField(key: "license")
  /// The license as Patra names it (`MIT License`, `Apache 2.0`), not an SPDX identifier.
  var license: String?

  @OptionalField(key: "framework")
  /// Model cards only: the framework the model runs on, such as `PyTorch`.
  var framework: String?

  @OptionalField(key: "model_type")
  /// Model cards only: Patra's description of the architecture, such as `cnn`.
  var modelType: String?

  @OptionalField(key: "input_type")
  /// Model cards only: what the model takes in, such as `images`.
  var inputType: String?

  @OptionalField(key: "accuracy")
  /// Model cards only: `ai_model.test_accuracy` as Patra reports it, normally a fraction in
  /// `0...1`. Stored unscaled; a card that reports a percentage shows as one.
  var accuracy: Double?

  @OptionalField(key: "keywords")
  /// Model cards only: the comma-separated keyword string exactly as Patra sends it. Split into a
  /// list in `PatraCard.Public`, not here, so the column stays a faithful copy of the source.
  var keywords: String?

  @OptionalField(key: "is_gated")
  /// Model cards only: Patra's `is_gated` flag, as reported. What gating involves is Patra's to
  /// define; this only records whether the card says it applies.
  var isGated: Bool?

  @OptionalField(key: "size")
  /// Datasheets only: Patra's free-text size, such as `~1.56 GB (1,000-10,000 images)`.
  var size: String?

  @OptionalField(key: "format")
  /// Datasheets only: Patra's free-text format, such as `JPEG`.
  var format: String?

  @OptionalField(key: "publication_year")
  /// Datasheets only: the DataCite publication year.
  var publicationYear: Int?

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
