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
