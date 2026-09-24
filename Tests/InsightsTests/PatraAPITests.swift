import Fluent
import Foundation
import Queues
import Testing
import Vapor

@testable import Insights

/// A JSON body wrapped in a `ClientResponse`. Duplicated from `TestSupport.swift`'s
/// file-private helper of the same name rather than shared, since that one is not visible
/// outside its file.
private func jsonResponse(_ status: HTTPResponseStatus, _ body: String) -> ClientResponse {
  ClientResponse(
    status: status,
    headers: ["Content-Type": "application/json"],
    body: ByteBuffer(string: body),
  )
}

/// The error a call threw, or nil if it succeeded. `JobError` is not `Equatable`, so callers
/// pattern-match the case they expect.
private func thrownJobError(_ body: () async throws -> Void) async -> JobError? {
  do {
    try await body()
    return nil
  } catch {
    return error as? JobError
  }
}

/// `PatraAPI.page` is the defect most likely to ship working and break later: Patra's list
/// endpoints paginate, and a fetch that only ever reads the first page looks correct right up
/// until the registry crosses the page boundary. These drive the loop directly against
/// `stubPagedAPI`, without either collector job that will sit on top of it in later tasks.
@Suite("PatraAPI", .serialized)
struct PatraAPITests {
  @Test
  func `A single short page returns everything in one request`() async throws {
    try await withInsightsApp { app in
      let requests = stubPagedAPI(on: app) { url in
        guard url.contains("/modelcards"), url.contains("skip=0") else { return nil }
        return jsonResponse(
          .ok, #"[{"uuid":"a","name":"first"},{"uuid":"b","name":"second"}]"#)
      }

      let cards = try await PatraAPI.page(
        queueContext(for: app), path: "/modelcards", as: PatraModelCard.self)

      #expect(cards.map(\.uuid) == ["a", "b"])
      #expect(requests.withLockedValue { $0.count } == 1)
    }
  }

  @Test
  func `A full page followed by a short page makes two requests and concatenates both`()
    async throws
  {
    try await withInsightsApp { app in
      // A full page (100 entries) so the loop must ask again; the second page is short so it
      // must stop rather than requesting a third.
      let firstPage = (0..<100).map { #"{"uuid":"first-\#($0)","name":"n"}"# }
        .joined(separator: ",")

      let requests = stubPagedAPI(on: app) { url in
        guard url.contains("/modelcards") else { return nil }
        if url.contains("skip=0") { return jsonResponse(.ok, "[\(firstPage)]") }
        if url.contains("skip=100") {
          return jsonResponse(.ok, #"[{"uuid":"second-0","name":"n"}]"#)
        }
        return nil
      }

      let cards = try await PatraAPI.page(
        queueContext(for: app), path: "/modelcards", as: PatraModelCard.self)

      #expect(cards.count == 101)
      #expect(cards.last?.uuid == "second-0")

      let urls = requests.withLockedValue { $0.map { $0.url.string } }
      #expect(urls.count == 2)
      // The regression this guards against: a loop that never advances `skip` would request
      // `skip=0` twice and silently drop the second page's content on the floor.
      #expect(urls[1].contains("skip=100"))
    }
  }

  @Test
  func `A non-200 response throws apiRequestFailed`() async throws {
    try await withInsightsApp { app in
      stubPagedAPI(on: app) { url in
        guard url.contains("/modelcards") else { return nil }
        return jsonResponse(.internalServerError, #"{"detail":"boom"}"#)
      }

      let error = await thrownJobError {
        _ = try await PatraAPI.page(
          queueContext(for: app), path: "/modelcards", as: PatraModelCard.self)
      }

      guard case .apiRequestFailed = error else {
        Issue.record("Expected .apiRequestFailed, got \(String(describing: error))")
        return
      }
    }
  }

  @Test
  func `Malformed JSON throws decodingFailed`() async throws {
    try await withInsightsApp { app in
      stubPagedAPI(on: app) { url in
        guard url.contains("/modelcards") else { return nil }
        // An object where the loop expects an array of cards.
        return jsonResponse(.ok, #"{"unexpected": true}"#)
      }

      let error = await thrownJobError {
        _ = try await PatraAPI.page(
          queueContext(for: app), path: "/modelcards", as: PatraModelCard.self)
      }

      guard case .decodingFailed = error else {
        Issue.record("Expected .decodingFailed, got \(String(describing: error))")
        return
      }
    }
  }
}

/// Nothing above exercises `PatraAPI.timestamps` itself — every stub in `PatraAPITests` above
/// omits `updated_at` entirely. That left the formatter asserted by no test even though two
/// consumers depend on it: `SyncPatraCatalog.register` silently drops a parse failure into a
/// permanently NULL `card_updated_at` (`.flatMap`), and `PatraCatalogAugust2026` force-unwraps it,
/// which would crash every `.development` boot — a migration nothing in `just test` ever runs,
/// since it is Postgres-seed-only and registered outside `.testing` (see `configure.swift`).
@Suite("PatraAPI.timestamps")
struct PatraAPITimestampsTests {
  @Test
  func `Parses a real Patra value with a colon-separated UTC offset`() throws {
    // Taken verbatim from the live API via `data/patra-modelcards.json`. Patra's own `updated_at`
    // always ends `+00:00` — an offset with a colon — never `Z`, which is the shape the formatter
    // most obviously supports at a glance. `ISO8601DateFormatter`'s `.withInternetDateTime`
    // already parses a colon-separated offset without needing `.withColonSeparatorInTimeZone`
    // added explicitly, confirmed here rather than assumed.
    let raw = "2026-07-30T16:38:28.157335+00:00"
    let parsed = try #require(PatraAPI.timestamps.date(from: raw))

    let expected = DateComponents(
      calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(secondsFromGMT: 0),
      year: 2026, month: 7, day: 30, hour: 16, minute: 38, second: 28,
    ).date!.addingTimeInterval(0.157)

    // Within a millisecond, not exact: `.withFractionalSeconds` keeps three fractional digits,
    // so Patra's microseconds (`157335`) truncate to `157` rather than rejecting the value.
    #expect(abs(parsed.timeIntervalSince(expected)) < 0.001)
  }

  @Test
  func `Parses every updated_at value the August 2026 seed carries, with no crash`() throws {
    // `PatraCatalogAugust2026`'s `CardSpec.updatedAt` literals are hand-transcribed from these
    // same two files (see its doc comment) and fed to `PatraAPI.timestamps.date(from:)!` — a
    // force-unwrap, because "every string here is a literal copied from the captured export" is
    // exactly the assumption this test checks rather than trusts. The migration's own values are
    // `private`, so this reads the real captured JSON directly instead of duplicating them by
    // hand a third time.
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PatraAPITests.swift
      .deletingLastPathComponent()  // InsightsTests
      .deletingLastPathComponent()  // Tests
    let fixtures = [
      "data/patra-modelcards.json",
      "data/patra-datasheets.json",
    ]

    struct RawCatalogEntry: Decodable {
      let updatedAt: String
      enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
      }
    }

    var checked = 0
    for fixture in fixtures {
      let url = repoRoot.appendingPathComponent(fixture)
      let data = try Data(contentsOf: url)
      let entries = try JSONDecoder().decode([RawCatalogEntry].self, from: data)
      #expect(!entries.isEmpty)

      for entry in entries {
        #expect(
          PatraAPI.timestamps.date(from: entry.updatedAt) != nil,
          "Failed to parse \(entry.updatedAt) from \(fixture)",
        )
        checked += 1
      }
    }

    // Guards the guard: if both files were empty or unreadable, every `#expect` above would have
    // passed vacuously and this test would prove nothing.
    #expect(checked == 43)
  }
}

// MARK: - Descriptive fields

/// A `/modelcard/{uuid}` detail response in the live API's shape, trimmed from the real BioCLIP 2
/// card: every key the endpoint sends, including the ones nothing here reads (`citation`,
/// `input_data`, `ai_model.model_id`), so decoding is proven against the whole object rather than
/// a hand-picked subset of it.
let bioclipModelCardDetailJSON = #"""
  {
    "uuid": "8c517ed0-c9c0-4f57-bb9d-f066ab4ec34e",
    "name": "BioCLIP 2 (via pybioclip)",
    "version": "v2.0",
    "short_description": "Biology foundation model for taxonomic classification and trait prediction.",
    "full_description": "BioCLIP 2 is a large-scale vision-language foundation model.",
    "keywords": "biology, taxonomy, wildlife, organism detection, zero-shot",
    "author": "John Bradley / Imageomics Institute",
    "input_data": "https://huggingface.co/datasets/imageomics/TreeOfLife-200M",
    "output_data": "https://github.com/Imageomics/pybioclip",
    "input_type": "images",
    "categories": "classification",
    "citation": "",
    "foundational_model": "",
    "training_datasheet_uuid": null,
    "is_private": false,
    "is_gated": false,
    "ai_model": {
      "model_id": 43,
      "name": "BioCLIP 2",
      "version": "BioCLIP 2.0",
      "description": "The current SOTA model for zero-shot species classification.",
      "owner": "Imageomics Institute / Ohio State University",
      "location": "https://huggingface.co/imageomics/bioclip-2",
      "license": "MIT License",
      "framework": "PyTorch / OpenCLIP",
      "model_type": "multimodal biological foundation model",
      "test_accuracy": 0.88
    }
  }
  """#

/// A `/datasheets` list entry in the live API's shape: the real CAN Benchmark entry, which carries
/// no `version` key at all.
let canBenchmarkDatasheetJSON = #"""
  {
    "uuid": "2a7b541d-d3d4-4969-8639-576830ad3d95",
    "title": "Continually Adapt or Not (CAN) Benchmark",
    "creator": "ICICLE AI Institute",
    "category": "Camera trap",
    "is_private": false,
    "updated_at": "2026-06-03T22:28:37.608303+00:00"
  }
  """#

/// The matching `/datasheet/{uuid}` detail, trimmed from the real CAN Benchmark response: two
/// descriptions (`Abstract` then `TechnicalInfo`, as two live datasheets have), DataCite objects
/// with their full key sets, and the identifier arrays provenance reads.
let canBenchmarkDatasheetDetailJSON = #"""
  {
    "uuid": "2a7b541d-d3d4-4969-8639-576830ad3d95",
    "publication_year": 2025,
    "resource_type": "Image dataset",
    "resource_type_general": "Dataset",
    "size": "~1.56 GB (1,000-10,000 images)",
    "format": "ImageFolder (images, distributed as CDB_D06.zip)",
    "version": "main@4c298e0 (2025-10-11)",
    "is_private": false,
    "updated_at": "2026-06-03T22:28:37.608303+00:00",
    "creators": [{"creator_name": "ICICLE AI Institute", "name_type": "Organizational",
      "lang": null, "given_name": null, "family_name": null, "affiliation": null}],
    "titles": [{"title": "Continually Adapt or Not (CAN) Benchmark", "title_type": null,
      "lang": "en"}],
    "publisher": {"name": "Hugging Face", "publisher_identifier": "https://huggingface.co"},
    "subjects": [{"subject": "Camera trap", "subject_scheme": null, "lang": "en"},
      {"subject": "Continual adaptation", "subject_scheme": null, "lang": "en"}],
    "contributors": [],
    "dates": [{"date": "2025-09-25", "date_type": "Available"}],
    "alternate_identifiers": [{"alternate_identifier": "ICICLE-AI/CAN_Benchmark",
      "alternate_identifier_type": "HuggingFace"}],
    "related_identifiers": [{"related_identifier":
      "https://huggingface.co/datasets/ICICLE-AI/CAN_Benchmark", "related_identifier_type": "URL",
      "relation_type": "IsVariantFormOf"}],
    "rights_list": [{"rights": "MIT License", "rights_uri": "https://opensource.org/license/mit",
      "rights_identifier": "MIT", "rights_identifier_scheme": "SPDX", "lang": "en"}],
    "descriptions": [
      {"description": "The CAN Benchmark is a curated ICICLE benchmark.",
        "description_type": "Abstract", "lang": "en"},
      {"description": "Temporally split camera trap images.", "description_type": "TechnicalInfo",
        "lang": "en"}],
    "geo_locations": [],
    "funding_references": []
  }
  """#

/// Decodes `json` as `type` with a plain `JSONDecoder`, which is what Vapor's content decoder is
/// for these types: none of them carries a date or a custom key strategy.
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// Replaces one top-level or nested `"key": value` pair in a fixture. Tests below change one field
/// at a time against a real-shaped fixture rather than each maintaining a near-copy of it.
private func replacing(_ json: String, _ original: String, with replacement: String) -> String {
  precondition(json.contains(original), "fixture no longer contains \(original)")
  return json.replacingOccurrences(of: original, with: replacement)
}

/// What `SyncPatraCatalog` reads off a card's detail (and, for a datasheet, its list entry) to
/// describe it. Pure decoding and mapping, no database: the fallback order and the leniency are
/// both properties of `PatraAPI.swift` alone.
@Suite("Patra card descriptions")
struct PatraCardDescriptionTests {
  @Test
  func `A real model card detail yields every model field`() throws {
    let detail = try decode(PatraModelCardDetail.self, bioclipModelCardDetailJSON)

    #expect(
      PatraCardDescription(modelCard: detail)
        == PatraCardDescription(
          description:
            "Biology foundation model for taxonomic classification and trait prediction.",
          author: "John Bradley / Imageomics Institute",
          category: "classification",
          license: "MIT License",
          framework: "PyTorch / OpenCLIP",
          modelType: "multimodal biological foundation model",
          inputType: "images",
          accuracy: 0.88,
          keywords: "biology, taxonomy, wildlife, organism detection, zero-shot",
          isGated: false,
        ))
    // Provenance still decodes exactly as before the descriptive fields existed.
    #expect(detail.aiModel?.location == "https://huggingface.co/imageomics/bioclip-2")
    #expect(detail.trainingDatasheetUUID == nil)
  }

  @Test
  func `A real datasheet list entry and detail yield every datasheet field`() throws {
    let sheet = try decode(PatraDatasheet.self, canBenchmarkDatasheetJSON)
    let detail = try decode(PatraDatasheetDetail.self, canBenchmarkDatasheetDetailJSON)

    #expect(sheet.version == nil)
    #expect(
      PatraCardDescription(datasheet: sheet, detail: detail)
        == PatraCardDescription(
          // The first description, the `Abstract`, not the `TechnicalInfo` after it.
          description: "The CAN Benchmark is a curated ICICLE benchmark.",
          author: "ICICLE AI Institute",
          category: "Camera trap",
          license: "MIT License",
          size: "~1.56 GB (1,000-10,000 images)",
          format: "ImageFolder (images, distributed as CDB_D06.zip)",
          publicationYear: 2025,
        ))
    #expect(detail.alternateIdentifiers?.first?.identifier == "ICICLE-AI/CAN_Benchmark")
    #expect(detail.relatedIdentifiers?.first?.relationType == "IsVariantFormOf")
  }

  /// The live "Faux weed detection" card sends `"short_description": ""`. Empty must mean "none"
  /// so the chain moves on to `ai_model.description`, and a null `ai_model.description` moves it
  /// on again to `full_description`.
  @Test
  func `An empty short description falls back to the AI model's, then to the full description`()
    throws
  {
    let emptyShort = replacing(
      bioclipModelCardDetailJSON,
      #""short_description": "Biology foundation model for taxonomic classification and trait prediction.""#,
      with: #""short_description": "   ""#)
    let toModel = try decode(PatraModelCardDetail.self, emptyShort)
    #expect(
      PatraCardDescription(modelCard: toModel).description
        == "The current SOTA model for zero-shot species classification.")

    let noModelDescription = replacing(
      emptyShort,
      #""description": "The current SOTA model for zero-shot species classification.""#,
      with: #""description": null"#)
    let toFull = try decode(PatraModelCardDetail.self, noModelDescription)
    #expect(
      PatraCardDescription(modelCard: toFull).description
        == "BioCLIP 2 is a large-scale vision-language foundation model.")
  }

  @Test
  func `A missing author falls back to the AI model's owner`() throws {
    let json = replacing(
      bioclipModelCardDetailJSON, #""author": "John Bradley / Imageomics Institute""#,
      with: #""author": null"#)
    let detail = try decode(PatraModelCardDetail.self, json)

    #expect(
      PatraCardDescription(modelCard: detail).author
        == "Imageomics Institute / Ohio State University")
  }

  /// Six live cards send `"keywords": null`, and an array is the shape a schema change would most
  /// plausibly bring. Both decode, and the array is joined into the same stored string shape.
  @Test
  func `Keywords decode from a string, an array, or null`() throws {
    let original = #""keywords": "biology, taxonomy, wildlife, organism detection, zero-shot""#

    let array = try decode(
      PatraModelCardDetail.self,
      replacing(
        bioclipModelCardDetailJSON, original, with: #""keywords": [" biology ", "", "taxonomy"]"#))
    #expect(array.keywords == "biology, taxonomy")

    let null = try decode(
      PatraModelCardDetail.self,
      replacing(bioclipModelCardDetailJSON, original, with: #""keywords": null"#))
    #expect(null.keywords == nil)

    let blank = try decode(
      PatraModelCardDetail.self,
      replacing(bioclipModelCardDetailJSON, original, with: ##""keywords": """##))
    #expect(blank.keywords == nil)
  }

  @Test
  func `test_accuracy reads a number or a numeric string, and nothing else`() throws {
    let original = #""test_accuracy": 0.88"#
    func accuracy(_ replacement: String) throws -> Double? {
      try decode(
        PatraModelCardDetail.self,
        replacing(bioclipModelCardDetailJSON, original, with: replacement)
      ).aiModel?.testAccuracy
    }

    #expect(try accuracy(#""test_accuracy": " 0.91 ""#) == 0.91)
    #expect(try accuracy(#""test_accuracy": 1"#) == 1)
    #expect(try accuracy(#""test_accuracy": null"#) == nil)
    #expect(try accuracy(#""test_accuracy": "85%""#) == nil)
    // Refused rather than stored: `JSONEncoder` throws on a non-finite Double, so one stored NaN
    // would fail every `GET /api/resources`.
    #expect(try accuracy(#""test_accuracy": "nan""#) == nil)
    #expect(try accuracy(#""test_accuracy": {"value": 0.9}"#) == nil)
  }

  /// The guarantee the leniency exists for: a type drift in any one descriptive field costs that
  /// value, never the response it arrived in.
  @Test
  func `Type drift in descriptive fields decodes to nil instead of throwing`() throws {
    var json = bioclipModelCardDetailJSON
    json = replacing(json, #""is_gated": false"#, with: #""is_gated": "no""#)
    json = replacing(json, #""categories": "classification""#, with: #""categories": ["a"]"#)
    json = replacing(json, #""input_type": "images""#, with: #""input_type": 3"#)
    json = replacing(json, #""license": "MIT License""#, with: #""license": {"spdx": "MIT"}"#)

    let detail = try decode(PatraModelCardDetail.self, json)
    let description = PatraCardDescription(modelCard: detail)

    #expect(description.isGated == nil)
    #expect(description.category == nil)
    #expect(description.inputType == nil)
    #expect(description.license == nil)
    // The fields that did not drift are untouched by the ones that did.
    #expect(description.framework == "PyTorch / OpenCLIP")
    #expect(detail.aiModel?.location == "https://huggingface.co/imageomics/bioclip-2")
  }

  /// The one field deliberately kept strict inside `ai_model`: a lenient nil `location` would
  /// clear a resolved provenance link on the next save instead of failing where someone sees it.
  @Test
  func `A non-string location still fails the detail response`() {
    let json = replacing(
      bioclipModelCardDetailJSON, #""location": "https://huggingface.co/imageomics/bioclip-2""#,
      with: #""location": 42"#)

    #expect(throws: DecodingError.self) {
      try decode(PatraModelCardDetail.self, json)
    }
  }

  /// Every descriptive field null, as Patra sends them on its sparsest cards ("Faux weed
  /// detection" has no keywords, input type, license, framework, or accuracy).
  @Test
  func `A card with every descriptive field null decodes to an empty description`() throws {
    let json = #"""
      {"short_description": null, "full_description": null, "keywords": null, "author": null,
       "input_type": null, "categories": null, "is_gated": null, "training_datasheet_uuid": null,
       "ai_model": {"description": null, "owner": null, "location": null, "license": null,
         "framework": null, "model_type": null, "test_accuracy": null}}
      """#
    let detail = try decode(PatraModelCardDetail.self, json)

    #expect(PatraCardDescription(modelCard: detail) == PatraCardDescription())
  }

  /// `creator` and `category` come from the list first, and fall back to the first *usable*
  /// DataCite entry, past a blank one and past one that is not even an object.
  @Test
  func `A datasheet falls back to DataCite creators and subjects past unusable entries`() throws {
    var sheetJSON = canBenchmarkDatasheetJSON
    sheetJSON = replacing(
      sheetJSON, #""creator": "ICICLE AI Institute""#, with: #""creator": null"#)
    sheetJSON = replacing(sheetJSON, #""category": "Camera trap""#, with: #""category": 7"#)
    let sheet = try decode(PatraDatasheet.self, sheetJSON)
    #expect(sheet.uuid == "2a7b541d-d3d4-4969-8639-576830ad3d95")

    var detailJSON = canBenchmarkDatasheetDetailJSON
    detailJSON = replacing(
      detailJSON, #""creators": [{"creator_name": "ICICLE AI Institute","#,
      with:
        #""creators": ["not an object", {"creator_name": " "}, {"creator_name": "ICICLE AI Institute","#
    )
    detailJSON = replacing(
      detailJSON, #""subjects": [{"subject": "Camera trap","#,
      with: #""subjects": [{"subject": null}, {"subject": "Camera trap","#)
    detailJSON = replacing(
      detailJSON, #""descriptions": ["#, with: #""descriptions": [{"description": ""}, "#)
    let detail = try decode(PatraDatasheetDetail.self, detailJSON)

    let description = PatraCardDescription(datasheet: sheet, detail: detail)
    #expect(description.author == "ICICLE AI Institute")
    #expect(description.category == "Camera trap")
    #expect(description.description == "The CAN Benchmark is a curated ICICLE benchmark.")
  }

  @Test
  func `publication_year reads an integer or a numeric string`() throws {
    let original = #""publication_year": 2025"#
    func year(_ replacement: String) throws -> Int? {
      try decode(
        PatraDatasheetDetail.self,
        replacing(canBenchmarkDatasheetDetailJSON, original, with: replacement)
      ).publicationYear
    }

    #expect(try year(#""publication_year": "2014""#) == 2014)
    #expect(try year(#""publication_year": null"#) == nil)
    #expect(try year(#""publication_year": "circa 2014""#) == nil)
  }

  /// Two live datasheets (Ohio Small Animals, Snapshot Karoo) send an empty `rights_list` and a
  /// null `size` and `format`; a datasheet with every descriptive array missing is the limit case.
  @Test
  func `A datasheet with empty or missing DataCite arrays has nil fields, not an error`() throws {
    let sheet = try decode(
      PatraDatasheet.self, #"{"uuid":"s","title":"Snapshot Karoo","is_private":false}"#)
    let detail = try decode(
      PatraDatasheetDetail.self,
      #"{"rights_list": [], "size": null, "format": null, "related_identifiers": []}"#)

    #expect(PatraCardDescription(datasheet: sheet, detail: detail) == PatraCardDescription())
  }

  @Test
  func `Surrounding whitespace is trimmed from every string`() throws {
    let json = replacing(
      bioclipModelCardDetailJSON, #""framework": "PyTorch / OpenCLIP""#,
      with: #""framework": "\n  PyTorch / OpenCLIP \t""#)
    let detail = try decode(PatraModelCardDetail.self, json)

    #expect(PatraCardDescription(modelCard: detail).framework == "PyTorch / OpenCLIP")
  }
}
