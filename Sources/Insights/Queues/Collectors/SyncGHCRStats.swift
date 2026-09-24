import Fluent
import Foundation
import Queues
import Vapor

/// Minimal queue payload identifying the GHCR container package to synchronize.
struct GHCRResource: Codable {
  let id: UUID
}

/// Synchronizes a GHCR container package's downloads by reading its public package page.
///
/// A scrape rather than an API call, because GitHub's Packages API reports no download count. The
/// parsing lives in `GHCRPackagePage`; this job owns fetching, the fallback between owner kinds,
/// and the write. Why scraping, and why it runs on the shared `metrics` queue, is ADR 009.
struct SyncGHCRStats: AsyncJob, BackoffRetrying {
  typealias Payload = GHCRResource

  let baseURL = "https://github.com"

  /// Identifies this service to GitHub on every page request.
  ///
  /// Descriptive rather than a browser's: the requests are few and honest about what they are, and
  /// if GitHub ever needs to ask them to stop, the string says who to ask. The other GitHub
  /// collectors send the bare name, which the API requires; the web frontend requires nothing, so
  /// this one adds where to find the project.
  static let userAgent = "icicle-insights (+https://github.com/ICICLE-ai/icicle-insights)"

  /// Called once the retry budget is spent, never before.
  func error(_ context: QueueContext, _ error: any Error, _ payload: GHCRResource) async throws {
    await context.reportResourceSyncFailure(error, job: Self.name, resourceID: payload.id)
  }

  /// Fetches the package page, parses both figures, and writes them with the next booking.
  func dequeue(_ context: QueueContext, _ payload: GHCRResource) async throws {
    // `withDeleted: true` and the skip below, for the same reason as `SyncGitHubRepoStats`.
    guard
      let resource = try await Resource.query(on: context.application.db)
        .filter(\.$id == payload.id)
        .with(\.$account, withDeleted: true)
        .first()
    else {
      context.entryVanished(id: payload.id, job: Self.name)
      return
    }

    guard !resource.accountIsDeleted else {
      context.orphanSkipped(resource, job: Self.name)
      return
    }

    // No vault lookup and no `SecretProvider`, unlike GitHub and the Hub, and deliberately so.
    // The package page is public, and GitHub prints the same figures for an anonymous visitor, so
    // a credential would add nothing to what is collected. What it could add is reach: anything a
    // signed-in caller can see and an anonymous one cannot, such as a private package, would then
    // flow onto a dashboard that is itself public. That is Patra's reasoning, and it gives the same
    // answer here. It also means a GHCR account needs no vault entry at all.
    let page = try await fetchPackagePage(
      context, owner: resource.account.name, name: resource.name)

    let resourceID = try resource.requireID()

    // One transaction for every write, with the fetch above it, for the reason
    // `SyncGitHubRepoStats` gives: a retry after a late failure must not find the snapshot row of
    // the attempt that failed.
    try await context.application.db.transaction { db in
      // The chart's days summed: a trailing 30-day window, so it rises and falls with activity
      // and is never added to anything. Same shape as the Hub's `downloads`.
      try await Metric(
        resourceID: resourceID, reading: Double(page.trailingDownloads), type: .pulls
      ).create(on: db)

      // Set, not folded. GitHub states the lifetime figure itself, so assigning it is exact and
      // re-running a sweep is harmless. Folding the chart through a watermark instead would
      // count only from the first sweep onward, and start years short of what the page says.
      try await Metric.setAllTime(
        on: db,
        resourceID: resourceID,
        type: .pulls,
        reading: Double(page.totalDownloads)
      )

      // Same contract as the other collectors: the schedule advances only once the whole sweep
      // has landed.
      try await resource.recordSuccessfulCollection(on: db)
    }
  }

  /// The package page's addresses, in the order they are tried: as an organization's package,
  /// then as a user's.
  ///
  /// Two, because an `Account` records only a name, and GitHub files a package under the kind of
  /// owner that published it. Every ICICLE account is an organization, so the first answers in
  /// practice; the second keeps a personal account from failing with a bare 404 forever.
  ///
  /// The name is percent-encoded as one path segment. Container names may contain `/`, and
  /// GitHub's page takes it as `%2F`; left raw it would split the name into two segments and
  /// address a page that does not exist. Only RFC 3986's unreserved characters pass through, so
  /// the result is the same on every platform rather than depending on Foundation's path set.
  func packagePageURLs(owner: String, name: String) -> [URI] {
    let owner = Self.pathSegment(owner)
    let name = Self.pathSegment(name)
    return ["orgs", "users"].map { kind in
      URI(string: "\(baseURL)/\(kind)/\(owner)/packages/container/package/\(name)")
    }
  }

  /// Fetches and parses the package page, falling back from the organization address to the user
  /// address on a 404.
  ///
  /// **Redirects are followed by the HTTP client, not here.** A package linked to a repository
  /// answers its `/orgs/…` address with a 302 to `/{owner}/{repo}/pkgs/container/{name}`, which
  /// carries the same markup. Vapor's client is AsyncHTTPClient, built from
  /// `app.http.client.configuration`; `configure.swift` changes only its timeouts, so it keeps
  /// `HTTPClient.Configuration.RedirectConfiguration`'s default of following up to five redirects
  /// with cycle detection (async-http-client 1.35, `HTTPClient.swift`, `RedirectConfiguration`'s
  /// internal `init()`). It keeps `User-Agent` and `Accept` across the hop, and only strips
  /// credentials on a change of origin, of which there are none here. A 3xx reaching this function
  /// therefore means the redirect could not be followed, and it fails like any other status.
  func fetchPackagePage(_ context: QueueContext, owner: String, name: String) async throws
    -> GHCRPackagePage
  {
    let urls = packagePageURLs(owner: owner, name: name)

    for url in urls {
      let response = try await context.application.client.get(url) { req in
        req.headers.replaceOrAdd(name: .userAgent, value: Self.userAgent)
        req.headers.replaceOrAdd(name: .accept, value: "text/html")
      }

      switch response.status {
      case .ok:
        let html = response.body.map { String(buffer: $0) } ?? ""
        return try GHCRPackagePage(html: html, url: url.string)
      case .notFound:
        // Try the other owner kind. GitHub answers 404 both for a package that does not exist and
        // for a private one viewed anonymously, so nothing distinguishes the two here.
        continue
      default:
        throw JobError.apiRequestFailed(url: url, response: response)
      }
    }

    // Not the second response's body: it is GitHub's whole 404 page, and the first 500 characters
    // of its `<head>` tell an operator nothing the sentence below does not.
    throw JobError.apiRequestFailed(
      url: urls.last?.string ?? baseURL,
      statusCode: 404,
      message:
        "no public package page under either the organization or the user address; the package "
        + "is missing, renamed, or private"
    )
  }

  /// RFC 3986's unreserved characters, the only ones a path segment can carry unencoded on every
  /// platform. Foundation's `urlPathAllowed` differs between macOS and Linux, and allows `/`.
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// Percent-encodes `value` as a single path segment, so `a/b` becomes `a%2Fb`.
  static func pathSegment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }
}
