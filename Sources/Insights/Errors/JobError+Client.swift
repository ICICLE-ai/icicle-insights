import Foundation
import Vapor

extension JobError {
  /// Builds an `apiRequestFailed` that keeps the API's own account of the rejection.
  ///
  /// A status code on its own can be actively misleading: GitHub answers a request missing its
  /// `User-Agent` with a bare 403, indistinguishable in the log from an expired token or an
  /// exhausted rate limit. The reason is only ever in the body.
  static func apiRequestFailed(url: URI, response: ClientResponse) -> JobError {
    // Error bodies are short diagnostics, not payload, so a truncated copy loses nothing.
    let message =
      response.body
      .map { String(buffer: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }

    return .apiRequestFailed(
      url: url.string,
      statusCode: Int(response.status.code),
      message: message
    )
  }
}
