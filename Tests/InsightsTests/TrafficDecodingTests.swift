import Foundation
import Testing

@testable import Insights

/// The traffic endpoints are identical but for the name of their per-day array, and the
/// original decoder read only the top-level `count` — which is a rolling total, not a delta.
/// These pin the shape the fold depends on.
@Suite("GitHub traffic decoding")
struct TrafficDecodingTests {
  /// Mirrors the decoder installed in `configure`, which is what the job decodes through.
  private func decode(_ json: String) throws -> GitHubRepoTrafficResponse {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(GitHubRepoTrafficResponse.self, from: Data(json.utf8))
  }

  @Test
  func `Clones decode from the clones array`() async throws {
    let response = try decode(
      """
      {
        "count": 173,
        "uniques": 128,
        "clones": [
          { "timestamp": "2026-08-01T00:00:00Z", "count": 2, "uniques": 1 },
          { "timestamp": "2026-08-02T00:00:00Z", "count": 5, "uniques": 3 }
        ]
      }
      """
    )

    #expect(response.count == 173)
    #expect(response.days.count == 2)
    #expect(response.days.map(\.count) == [2, 5])
  }

  @Test
  func `Views decode from the views array`() async throws {
    let response = try decode(
      """
      {
        "count": 14850,
        "uniques": 3782,
        "views": [
          { "timestamp": "2026-08-01T00:00:00Z", "count": 100, "uniques": 40 }
        ]
      }
      """
    )

    #expect(response.count == 14850)
    #expect(response.days.count == 1)
    #expect(response.days.first?.uniques == 40)
  }

  /// A quiet repository comes back with the window totals and no day entries at all. The fold
  /// has to see an empty list rather than fail to decode.
  @Test
  func `A window with no traffic decodes to no days`() async throws {
    let response = try decode(#"{ "count": 0, "uniques": 0, "clones": [] }"#)

    #expect(response.count == 0)
    #expect(response.days.isEmpty)
  }

  /// The rolling total is deliberately kept — it is what the `clones`/`views` Metric row
  /// stores as a current-reach reading. It just must never reach the all-time total.
  @Test
  func `The rolling total is independent of the days it summarises`() async throws {
    let response = try decode(
      """
      {
        "count": 500,
        "uniques": 120,
        "clones": [ { "timestamp": "2026-08-01T00:00:00Z", "count": 3, "uniques": 2 } ]
      }
      """
    )

    #expect(response.count == 500)
    #expect(response.days.map(\.count).reduce(0, +) == 3)
  }
}
