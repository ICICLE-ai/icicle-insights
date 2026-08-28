import Fluent
import Foundation
import SQLKit

/// The real Patra catalog captured 2026-08-26 from the live `/modelcards` and `/datasheets`
/// endpoints, checked in at `data/patra-modelcards.json` and `data/patra-datasheets.json`.
/// Registered only in `.development` (see `configure.swift`), so it targets the `dev` database
/// and never `test`.
///
/// A Patra model card is a (name, version) pair, not a distinct model — see `SyncPatraCatalog`,
/// which discovers the same catalog live and applies the identical grouping rule. Grouping the 37
/// captured cards by `name` yields 23 distinct models; `MegaDetector for Wildlife Detection` alone
/// accounts for 11 of them, across ten versions and four authors. The 6 captured datasheets have 6
/// distinct titles, so each is its own resource with exactly one card. Every figure here is real:
/// 29 resources (23 model + 6 dataset), 43 cards, and the 3 deployment counts below, summed per
/// resource from the live `/modelcard/{uuid}/deployments` endpoint — the only resources with any
/// deployments recorded.
struct PatraCatalogAugust2026: AsyncMigration {
  /// Indicates that this PostgreSQL-specific seed migration received another database driver.
  struct UnsupportedDatabase: Error {}

  private static let accountName = "icicleai"
  private static let platform = Platform.patra
  private static let followers = 0

  /// When both source exports were captured, taken from their shared file timestamp. Used as
  /// every seeded resource's `nextCollectionAt` rather than the card timestamps below, which
  /// come from Patra's own `updated_at` per card.
  private static let snapshotDate = DateComponents(
    calendar: Calendar(identifier: .gregorian),
    timeZone: TimeZone(secondsFromGMT: 0),
    year: 2026, month: 8, day: 26, hour: 16, minute: 31, second: 55
  ).date!

  // MARK: Catalog

  private struct CardSpec {
    let uuid: String
    let version: String?
    let updatedAt: String

    init(_ uuid: String, version: String? = nil, updatedAt: String) {
      self.uuid = uuid
      self.version = version
      self.updatedAt = updatedAt
    }
  }

  private struct MetricSpec {
    let type: MetricType
    let reading: Double

    init(_ type: MetricType, _ reading: Double) {
      self.type = type
      self.reading = reading
    }
  }

  private struct ResourceSpec {
    let name: String
    let type: ResourceType
    let metrics: [MetricSpec]
    let cards: [CardSpec]

    init(_ name: String, type: ResourceType, metrics: [MetricSpec] = [], cards: [CardSpec]) {
      self.name = name
      self.type = type
      self.metrics = metrics
      self.cards = cards
    }
  }

  /// Grouped from the 37 captured model cards in `data/patra-modelcards.json` by `name` — a
  /// Patra card is a (name, version) pair, not a distinct model (see `SyncPatraCatalog`).
  /// 23 distinct names result; `MegaDetector for Wildlife Detection` alone is 11 of the 37 cards.
  private static let modelResources: [ResourceSpec] = [
    ResourceSpec(
      "beans-disease-classifier", type: .model,
      cards: [
        .init(
          "b989e41f-fdd4-4fac-b942-95c224c4c942", version: "1.0",
          updatedAt: "2026-07-30T16:38:28.157335+00:00"),
        .init(
          "c4f5ae58-4c83-4677-bcd2-195ad7c0186a", version: "1.0",
          updatedAt: "2026-08-03T16:59:41.812667+00:00"),
      ]),
    ResourceSpec(
      "BioCLIP 2 (via pybioclip)", type: .model,
      cards: [
        .init(
          "8c517ed0-c9c0-4f57-bb9d-f066ab4ec34e", version: "v2.0",
          updatedAt: "2026-05-22T19:50:39.783085+00:00")
      ]),
    ResourceSpec(
      "Crop Weed YOLO Model CNW", type: .model,
      cards: [
        .init(
          "b404980f-438a-4760-b358-f6325e6c8f2d", version: "v1",
          updatedAt: "2026-05-04T23:18:53.064965+00:00")
      ]),
    ResourceSpec(
      "Deeplab_V3 Engine", type: .model,
      cards: [
        .init(
          "b521f10c-6845-44cd-9021-5bf407472633", version: "1.0.0",
          updatedAt: "2026-06-11T20:41:26.003210+00:00")
      ]),
    ResourceSpec(
      "GoogLeNet for Image Classification", type: .model,
      cards: [
        .init(
          "31b191a5-121c-4b5f-8266-f99da0f6580f", version: "1.0",
          updatedAt: "2026-05-04T23:18:53.064965+00:00")
      ]),
    ResourceSpec(
      "Grounding DINO â€” grounded open-vocabulary detection", type: .model,
      cards: [
        .init(
          "62cb5c70-08fc-4899-9522-483274e21ef2", version: "1.0",
          updatedAt: "2026-05-05T05:14:47.194483+00:00")
      ]),
    ResourceSpec(
      "HybridEnd2EndLearner", type: .model,
      cards: [
        .init(
          "558461ca-d567-4597-976a-6f09c98bb14d", version: "5a",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "71f7a75b-6b91-464c-9bb0-c79f4a4a0089", version: "0.0.1",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
      ]),
    ResourceSpec(
      "MegaDetector for Wildlife Detection", type: .model, metrics: [.init(.deployments, 52)],
      cards: [
        .init(
          "bbbe80fc-1ec4-4de5-a2a4-0a2f2f46a2d6", version: "5a (OSA finetuning)",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "c10ae550-e292-4125-9308-cfc16da26ae1", version: "6b-yolov9c (OSA finetuning 20 epochs)",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "48686879-cb55-4b02-8150-a37d2107a9be", version: "5a (OSA finetuning 50 epochs)",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "1cc82313-4175-4dd3-8ee6-93528626e54e", version: "6b-yolov9c (OSA finetuning)",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "022166bc-364b-4ef7-9aaf-84ca836c9caf", version: "6b-yolov9c (OSA finetuning 20 epochs)",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "7032820a-3c6f-48bf-a9be-a4ae4f820efa", version: "5a",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "f37ba0f9-8340-43fd-9cac-63ee346f0620", version: "5b",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "6a2f13b5-11d8-4c0c-84fb-2d83a16fff71", version: "5-optimized",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "e326dee9-efa2-4cab-bb8b-4289f64c43df", version: "5c",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "1d8c7448-32e6-4bac-b17f-cf925d8d9705", version: "5a_ena",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "ea991e85-feaa-4781-a297-4d7bec1a69b1", version: "6b-yolov9c",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
      ]),
    ResourceSpec(
      "MobileNetV2_Inference_Demo", type: .model, metrics: [.init(.deployments, 1)],
      cards: [
        .init(
          "1bc537bf-4073-425a-a736-cfbfcc08e040", version: "1.0",
          updatedAt: "2026-07-22T16:34:43.074765+00:00"),
        .init(
          "f673293c-679d-41f7-94cd-ac7ea62b5fc0", version: "1.0-pipelinecheck827242",
          updatedAt: "2026-07-23T17:20:45.621773+00:00"),
      ]),
    ResourceSpec(
      "OWLv2 Large Patch14 Ensemble", type: .model,
      cards: [
        .init(
          "04ac0992-d0ab-4a50-8a4f-92a5da89d848", version: "ViT-L/14 Ensemble (Self-Trained)",
          updatedAt: "2026-05-22T19:59:12.926027+00:00")
      ]),
    ResourceSpec(
      "ResNet50 Image Classification Model", type: .model, metrics: [.init(.deployments, 16)],
      cards: [
        .init(
          "56e0fc98-f6dd-4994-a6e3-dc6ca0f4f5e6", version: "1.0",
          updatedAt: "2026-05-04T23:18:53.064965+00:00")
      ]),
    ResourceSpec(
      "SAM3 â€” segmentation-assisted detection", type: .model,
      cards: [
        .init(
          "e5dc3154-be11-42dd-828c-3869d52c4301", version: "1.0",
          updatedAt: "2026-05-05T05:00:14.073089+00:00")
      ]),
    ResourceSpec(
      "test", type: .model,
      cards: [
        .init(
          "58ee4dbd-fbce-4357-970f-66d9617ecc59", version: "1.0",
          updatedAt: "2026-07-29T21:15:13.562292+00:00")
      ]),
    ResourceSpec(
      "Ultralytics YOLO", type: .model,
      cards: [
        .init(
          "4828d055-bba8-4e63-add8-7cd6c4707507", version: "9e",
          updatedAt: "2026-05-04T23:18:53.064965+00:00")
      ]),
    ResourceSpec(
      "Ultralytics Yolo 26 base - Temp", type: .model,
      cards: [
        .init(
          "4012f44e-dcf0-4452-a9b6-43902444713a", version: "1.0.0",
          updatedAt: "2026-07-28T20:30:54.144977+00:00")
      ]),
    ResourceSpec(
      "Ultralytics YOLO26n", type: .model,
      cards: [
        .init(
          "931784c7-659c-4ffc-aff6-327d2ed3e74c", version: "26n",
          updatedAt: "2026-06-16T22:28:05.738619+00:00")
      ]),
    ResourceSpec(
      "Ultralytics YOLO26x", type: .model,
      cards: [
        .init(
          "b7078179-b92e-4906-8a1a-70bd0bc34a70", version: "26x",
          updatedAt: "2026-05-04T23:18:53.064965+00:00")
      ]),
    ResourceSpec(
      "Unet++ Corn Residue Segmentation [AGX-Xavier-JP4-MVS]", type: .model,
      cards: [
        .init(
          "2a25c561-9cbd-46f8-bc92-271d29c14862", version: "1.0",
          updatedAt: "2026-07-02T17:17:40.269477+00:00")
      ]),
    ResourceSpec(
      "Unetpp", type: .model,
      cards: [
        .init(
          "56a980ad-ca95-430f-817a-09d93b90d7aa", version: "1.0.0",
          updatedAt: "2026-05-19T02:29:54.980024+00:00")
      ]),
    ResourceSpec(
      "Yield Estimation", type: .model,
      cards: [
        .init(
          "d823466b-1d30-4248-b0ee-86fae17ef53f", version: nil,
          updatedAt: "2026-08-21T05:20:04.664613+00:00")
      ]),
    ResourceSpec(
      "YOLOE", type: .model,
      cards: [
        .init(
          "9d7601a7-5b43-4ef4-aea0-6eb29edd7929", version: "1.0",
          updatedAt: "2026-05-05T05:12:43.977399+00:00")
      ]),
    ResourceSpec(
      "Yolo Object Detecion - for detecting a soft toy", type: .model,
      cards: [
        .init(
          "bb92bb21-7cc1-425e-a25a-a1d9ac38513f", version: "yolo11l_ep1_bs32_lr0.005_8aa95a86.pt",
          updatedAt: "2026-05-04T23:18:53.064965+00:00")
      ]),
    ResourceSpec(
      "Yolo_Object_Detecion__SoftToy", type: .model,
      cards: [
        .init(
          "680c07c7-2343-48a0-a37b-e6bda9e1b312", version: "yolo11l_ep1_bs32_lr0.005_8aa95a86.pt",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
        .init(
          "319838e5-5a84-47d6-b2a2-e6606ab56707", version: "yolo11l_ep1_bs32_lr0_005_8aa95a86.pt",
          updatedAt: "2026-05-04T23:18:53.064965+00:00"),
      ]),
  ]

  /// The 6 captured datasheets in `data/patra-datasheets.json`, each with a distinct `title` —
  /// unlike model cards, no datasheet repeats a title under a different version.
  private static let datasetResources: [ResourceSpec] = [
    ResourceSpec(
      "Continually Adapt or Not (CAN) Benchmark", type: .dataset,
      cards: [
        .init("2a7b541d-d3d4-4969-8639-576830ad3d95", updatedAt: "2026-06-03T22:28:37.608303+00:00")
      ]),
    ResourceSpec(
      "HLO Feature Dataset for Deep Learning Resource Estimation", type: .dataset,
      cards: [
        .init("ab55bd2e-5146-4509-b862-cc0292626456", updatedAt: "2026-06-03T22:28:37.608303+00:00")
      ]),
    ResourceSpec(
      "Lorem Picsum Sample Images", type: .dataset,
      cards: [
        .init("d169e2ed-2435-49f0-93ef-207abcc44ede", updatedAt: "2026-07-29T21:37:55.768238+00:00")
      ]),
    ResourceSpec(
      "Ohio Small Animals", type: .dataset,
      cards: [
        .init("49fff6a8-b6a7-4e6c-997a-f1ea4724ec5f", updatedAt: "2026-07-10T19:24:49.200602+00:00")
      ]),
    ResourceSpec(
      "Organization SIC Code Dataset", type: .dataset,
      cards: [
        .init("2c29fa56-7cc5-4264-a429-e30afc357af4", updatedAt: "2026-06-03T22:28:37.608303+00:00")
      ]),
    ResourceSpec(
      "Snapshot Karoo", type: .dataset,
      cards: [
        .init("b56b258e-50bd-421f-9374-d9de88a1cb3e", updatedAt: "2026-07-17T15:56:55.062294+00:00")
      ]),
  ]

  // MARK: Migration

  /// Inserts the seeded account, resources, cards, and deployment-count metrics.
  func prepare(on database: any Database) async throws {
    guard let sql = database as? any SQLDatabase else {
      throw UnsupportedDatabase()  // Postgres only; never reached in practice.
    }

    let account = Account(
      name: Self.accountName, platform: Self.platform, followers: Self.followers)
    try await account.create(on: database)
    let accountID = try account.requireID()

    // Collected across every resource so all readings go in as one statement, sharing a
    // timestamp. `Metric.recordedAt` is `@Timestamp(on: .create)`, which would otherwise
    // overwrite each row with "now" and scatter the sweep across many instants.
    var readings: [(resourceID: Resource.IDValue, spec: MetricSpec)] = []

    for resourceSpec in Self.modelResources + Self.datasetResources {
      let resource = Resource(
        name: resourceSpec.name,
        type: resourceSpec.type,
        accountID: accountID,
        // The live catalog sync books a freshly discovered resource for the very next sweep
        // (`SyncPatraCatalog`'s `nextCollectionAt: Date()`). Nil would leave these invisible to
        // `CollectDueResources` forever, so this mirrors that by booking them for the snapshot
        // date instead — already in the past by the time a dev stack boots, so its next hourly
        // tick picks every one of them up.
        nextCollectionAt: Self.snapshotDate,
      )
      try await resource.create(on: database)
      let resourceID = try resource.requireID()

      // `PatraCard.cardUpdatedAt` is `@OptionalField`, not `@Timestamp(on: .create)` — unlike
      // `Metric.recordedAt` above, storing it here does not fight the model over "now", so cards
      // can be created directly rather than needing the raw-SQL bulk insert readings get below.
      let cards = resourceSpec.cards.map {
        PatraCard(
          resourceID: resourceID,
          cardUUID: $0.uuid,
          version: $0.version,
          // Force-unwrapped: every string here is a literal copied from the captured export, and
          // `PatraAPI.timestamps` is the exact formatter `SyncPatraCatalog` parses live cards
          // with — if it can't parse our own literals, that formatter is broken for everyone.
          cardUpdatedAt: PatraAPI.timestamps.date(from: $0.updatedAt)!,
        )
      }
      try await cards.create(on: database)

      readings.append(contentsOf: resourceSpec.metrics.map { (resourceID, $0) })
    }

    try await insertMetrics(on: sql, readings: readings)
  }

  /// Removes only records introduced by this seed.
  func revert(on database: any Database) async throws {
    // Force-delete the account this seed owns; DB-level ON DELETE CASCADE removes its
    // resources and, through those resources, their cards and metrics.
    let accounts = try await Account.query(on: database)
      .filter(\.$name == Self.accountName)
      .filter(\.$platform == Self.platform)
      .all()
    for account in accounts {
      try await account.delete(force: true, on: database)
    }
  }

  /// Bulk-inserts every deployment reading at `snapshotDate`. A raw multi-row insert both
  /// sidesteps the `@Timestamp(on: .create)` "stamp now" behaviour and is far faster than a round
  /// trip per row.
  private func insertMetrics(
    on sql: any SQLDatabase,
    readings: [(resourceID: Resource.IDValue, spec: MetricSpec)]
  ) async throws {
    guard !readings.isEmpty else { return }

    var query = SQLQueryString(
      "INSERT INTO metrics (id, resource_id, reading, type, recorded_at) VALUES ")
    for (index, reading) in readings.enumerated() {
      if index > 0 {
        query.appendLiteral(", ")
      }
      query.appendLiteral("(")
      query.appendInterpolation(bind: UUID())
      query.appendLiteral(", ")
      query.appendInterpolation(bind: reading.resourceID)
      query.appendLiteral(", ")
      query.appendInterpolation(bind: reading.spec.reading)
      query.appendLiteral(", ")
      query.appendInterpolation(bind: reading.spec.type.rawValue)
      query.appendLiteral("::metric_type, ")
      query.appendInterpolation(bind: Self.snapshotDate)
      query.appendLiteral(")")
    }
    try await sql.raw(query).run()
  }
}
