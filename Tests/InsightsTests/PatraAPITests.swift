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
