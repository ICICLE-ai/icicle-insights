import Fluent
import Vapor

import struct Foundation.Date

extension PatraCard {
  /// Which of Patra's two catalogs a card came from.
  ///
  /// `datasheet`, not `dataset`: this names the Patra record the text came from, which Patra calls
  /// a datasheet, while the resource it describes keeps its own `type` of `dataset` alongside it.
  /// `CaseIterable` so the OpenAPI document lists the two values instead of a bare string.
  enum Kind: String, Codable, CaseIterable, Sendable {
    case model
    case datasheet

    /// The kind of card a resource of `resourceType` carries, or nil for a type Patra has no
    /// catalog for.
    ///
    /// Read off the owning resource because the card row does not record which endpoint it came
    /// from, and `SyncPatraCatalog` is what ties the two together: model cards register as
    /// `.model` and datasheets as `.dataset`. Any other type means an admin retyped the resource
    /// by hand, or Patra grew a catalog (`agent`) this projection does not know yet, and naming a
    /// kind there would be a guess. Nil drops the whole `card` rather than labelling it wrongly.
    /// Exhaustive on purpose, so a new `ResourceType` has to decide here.
    init?(resourceType: ResourceType) {
      switch resourceType {
      case .model: self = .model
      case .dataset: self = .datasheet
      case .agent, .container, .package, .repository, .service: return nil
      }
    }
  }

  /// A Patra card as the API shows it: the descriptive fields a gallery tile needs, on
  /// `Resource.Public.card`.
  ///
  /// Every field but `kind` and `uuid` is nullable, and encoded as an explicit `null` rather than
  /// left out when it has no value. A model card has no `size` and a datasheet no `framework`, and
  /// Patra leaves plenty more null besides; a client should read one fixed set of keys, not have
  /// to tell "absent" from "no value" by which keys happen to be present. That is the same choice
  /// `InsightTile` makes for `atStart`.
  struct Public: Content, Equatable {
    var kind: Kind
    /// Patra's own identifier for the card.
    var uuid: String
    var version: String?
    /// The card's `updated_at` in Patra, not when Insights last saw it.
    var updatedAt: Date?
    var description: String?
    var author: String?
    var category: String?
    var license: String?
    var framework: String?
    var modelType: String?
    var inputType: String?
    /// Normally a fraction in `0...1`, as Patra reports it.
    var accuracy: Double?
    /// Patra's comma-separated keywords, split and trimmed. Null rather than `[]` when there are
    /// none, like every other field here.
    var keywords: [String]?
    var gated: Bool?
    var size: String?
    var format: String?
    var publicationYear: Int?
    /// The card's cross-registry identifier as Patra recorded it, whether or not it resolved to a
    /// tracked resource. The resolved ones are in `Resource.Public.links`.
    var sourceURL: String?

    enum CodingKeys: String, CodingKey {
      case kind, uuid, version, updatedAt, description, author, category, license, framework,
        modelType, inputType, accuracy, keywords, gated, size, format, publicationYear, sourceURL
    }

    /// Written by hand so every nil field is an explicit `null`. Synthesized `Encodable` drops
    /// nil optionals, which is what `Resource.Public` itself relies on and what this must not do.
    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(kind, forKey: .kind)
      try container.encode(uuid, forKey: .uuid)
      try container.encode(version, forKey: .version)
      try container.encode(updatedAt, forKey: .updatedAt)
      try container.encode(description, forKey: .description)
      try container.encode(author, forKey: .author)
      try container.encode(category, forKey: .category)
      try container.encode(license, forKey: .license)
      try container.encode(framework, forKey: .framework)
      try container.encode(modelType, forKey: .modelType)
      try container.encode(inputType, forKey: .inputType)
      try container.encode(accuracy, forKey: .accuracy)
      try container.encode(keywords, forKey: .keywords)
      try container.encode(gated, forKey: .gated)
      try container.encode(size, forKey: .size)
      try container.encode(format, forKey: .format)
      try container.encode(publicationYear, forKey: .publicationYear)
      try container.encode(sourceURL, forKey: .sourceURL)
    }
  }

  /// Projects this card into the public shape, labelled with the `kind` its resource implies.
  func toPublic(kind: Kind) -> Public {
    Public(
      kind: kind,
      uuid: cardUUID,
      version: version,
      updatedAt: cardUpdatedAt,
      description: cardDescription,
      author: author,
      category: category,
      license: license,
      framework: framework,
      modelType: modelType,
      inputType: inputType,
      accuracy: accuracy,
      keywords: Self.splitKeywords(keywords),
      gated: isGated,
      size: size,
      format: format,
      publicationYear: publicationYear,
      sourceURL: sourceURL,
    )
  }

  /// Splits Patra's stored keyword string on commas into trimmed, non-empty keywords, or nil when
  /// none are left.
  ///
  /// Done here rather than at write time so `patra_cards.keywords` stays exactly what Patra sent.
  /// Order and duplicates are kept as Patra wrote them: this splits, it does not curate.
  static func splitKeywords(_ raw: String?) -> [String]? {
    guard let raw else { return nil }
    let keywords = raw.split(separator: ",").compactMap { PatraText.clean(String($0)) }
    return keywords.isEmpty ? nil : keywords
  }

  /// The card whose description should stand for a resource: the one Patra updated most recently.
  ///
  /// A resource groups every card under one name, so a model with eleven versions has eleven
  /// cards, and a gallery tile has room for one. The newest `card_updated_at` is the closest thing
  /// to "the current card" Patra offers. A card with no `card_updated_at` ranks below any card
  /// that has one, since an unknown date is not evidence of being recent. Ties fall to
  /// `created_at`, the card Insights discovered last, and then to `card_uuid`, which only exists so
  /// the same set of cards always picks the same one rather than whichever row the database
  /// returned first.
  static func newest(of cards: [PatraCard]) -> PatraCard? {
    cards.max { lhs, rhs in
      (lhs.cardUpdatedAt ?? .distantPast, lhs.createdAt ?? .distantPast, lhs.cardUUID)
        < (rhs.cardUpdatedAt ?? .distantPast, rhs.createdAt ?? .distantPast, rhs.cardUUID)
    }
  }
}
