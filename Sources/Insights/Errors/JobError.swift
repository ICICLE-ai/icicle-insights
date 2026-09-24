import Foundation
import Logging
import Vapor

/// Domain failures surfaced by platform synchronization jobs.
enum JobError: Error {
  case apiRequestFailed(url: String, statusCode: Int, message: String?)
  case missingToken(id: UUID)
  case decodingFailed(url: String, underlying: any Error)
  /// A scraped page answered 200 but no longer carries the markup its parser reads.
  ///
  /// Its own case rather than `decodingFailed`, because the remedy differs: a JSON API that stops
  /// decoding has usually changed a documented schema, whereas a web page changes whenever GitHub
  /// redesigns it, with no notice and no version. `detail` says which part went missing, so the
  /// alert alone points at the selector to fix.
  case pageLayoutChanged(url: String, detail: String)
}

/// `DebuggableError`, not a bare `Error`: `Logger.report(error:)` reads `reason` and `logLevel` off
/// this conformance. Without it every failure logs a reflected enum dump at `.warning`, which puts
/// a dead credential at the same severity as a transient 503.
extension JobError: DebuggableError {
  /// Stable key per failure kind, emitted as part of every reported line. Filterable in a log
  /// search in a way that prose never is.
  var identifier: String {
    switch self {
    case .apiRequestFailed: "api_request_failed"
    case .missingToken: "missing_token"
    case .decodingFailed: "decoding_failed"
    case .pageLayoutChanged: "page_layout_changed"
    }
  }

  /// A log-oriented explanation of the failed collection operation.
  var reason: String {
    switch self {
    case .apiRequestFailed(let url, let statusCode, let message):
      // The status alone is rarely enough: GitHub answers a missing header with a bare 403 and
      // explains itself only in the body.
      "API request to \(url) failed with status \(statusCode)"
        + (message.map { ": \($0)" } ?? "")
    case .missingToken(let id):
      "Account \(id) has no access token"
    case .decodingFailed(let url, let underlying):
      "Could not decode response from \(url): \(underlying)"
    case .pageLayoutChanged(let url, let detail):
      "The page at \(url) no longer has the layout its parser expects: \(detail)"
    }
  }

  /// Severity by what an operator has to do about it, not by where the failure happened.
  ///
  /// A rejected credential is the only kind that stays broken until someone acts, so it is the
  /// only one raised to `.critical`. Everything the remote might recover from on its own stays at
  /// `.warning` so a bad afternoon at GitHub does not read like an outage here.
  var logLevel: Logger.Level {
    switch self {
    case .missingToken:
      .critical
    case .apiRequestFailed(_, let statusCode, _):
      isCredentialStatus(statusCode) ? .critical : .warning
    case .decodingFailed, .pageLayoutChanged:
      // `.error`, alongside a body that will not decode: nothing retries its way past a changed
      // layout, but no credential is involved either, so it is not raised to `.critical`.
      .error
    }
  }

  /// Reaches both the log and the alert: `report(error:)` renders the `.short` form, which
  /// appends these inline as `[Suggested fixes: …]`, and the alert renders `.long`, which lists
  /// them as bullets. Write them as instructions to whoever is paged, not as commentary.
  var suggestedFixes: [String] {
    switch self {
    case .missingToken:
      ["Add a vault entry naming this account's platform token, then wait for the next sweep."]
    case .apiRequestFailed where isCredentialFailure:
      [
        "Check the platform token has not expired and still carries the scopes the endpoint needs.",
        "Rotate the token in Tapis Vault; collection resumes on the next hourly sweep.",
      ]
    case .pageLayoutChanged:
      // Named file and fixtures, because whoever is paged has probably never opened either, and
      // the parser is the only place that knows what the page is supposed to look like.
      [
        "GitHub has changed its package page. Open the URL above, find the new markup for the "
          + "download figures, and update the selectors in `GHCRPackagePage`.",
        "Replace the saved pages in `Tests/Fixtures/GHCR/` with a fresh copy, so the tests "
          + "describe the page GitHub serves now.",
      ]
    default:
      []
    }
  }

  /// 403 counts alongside 401: GitHub rejects an expired or under-scoped token with either.
  private func isCredentialStatus(_ statusCode: Int) -> Bool {
    statusCode == 401 || statusCode == 403
  }
}

extension JobError {
  /// Whether a later attempt is pointless until someone repairs a credential.
  ///
  /// Drives alerting and re-booking together: these are the failures worth waking someone for,
  /// and the only ones where retrying sooner than the normal cadence pays off, since the fix
  /// lands out of band and the next sweep would otherwise be days away.
  var isCredentialFailure: Bool {
    switch self {
    case .missingToken:
      true
    case .apiRequestFailed(_, let statusCode, _):
      isCredentialStatus(statusCode)
    case .decodingFailed, .pageLayoutChanged:
      // Not a credential failure: the page is public and fetched anonymously, so nothing an
      // operator rotates will fix it. It re-books on the ordinary backoff and alerts at warning.
      false
    }
  }
}
