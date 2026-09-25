import Foundation
import Vapor

/// The S3-compatible bucket database backups are uploaded to, read once at boot.
///
/// Every part is configuration because the provider is not chosen yet. AWS, MinIO and Ceph all
/// accept the same signed `PutObject`; they differ only in endpoint, region, addressing style and
/// whether they accept a server-side-encryption header.
struct BackupStorage: Sendable {
  let endpoint: Endpoint
  let region: String
  let bucket: String
  /// Prepended to every key. Always empty or ending in `/`.
  let prefix: String
  let accessKeyID: String
  let secretAccessKey: Secret
  /// `https://endpoint/bucket/key` rather than `https://bucket.endpoint/key`.
  ///
  /// The default, because self-hosted stores such as MinIO and Ceph answer path-style out of the
  /// box and virtual-hosted only once a domain is configured for them, and because a bucket name
  /// containing a dot breaks the TLS wildcard on virtual-hosted names. AWS answers both and
  /// prefers virtual-hosted, so `false` is the setting to reach for there.
  let pathStyle: Bool
  /// Whether to ask for SSE-S3 (`x-amz-server-side-encryption: AES256`).
  ///
  /// On by default so a dump never rests unencrypted on AWS. Switchable because MinIO without a
  /// key server refuses the header outright rather than ignoring it.
  let serverSideEncryption: Bool

  /// Where the bucket's API lives: scheme, host and optional port, nothing else.
  struct Endpoint: Sendable, Equatable {
    let scheme: String
    let host: String
    let port: Int?

    /// `host` or `host:port`, as the `Host` header and the URL both carry it.
    var authority: String {
      port.map { "\(host):\($0)" } ?? host
    }

    /// Parses `BACKUP_S3_ENDPOINT`.
    ///
    /// A path is refused rather than kept. Nothing here would prepend it to the signed path, so a
    /// Ceph gateway mounted under `/s3` would fail every upload with a signature mismatch that
    /// names neither the setting nor the cause.
    init(parsing raw: String) throws {
      guard let components = URLComponents(string: raw),
        let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = components.host, !host.isEmpty,
        components.path.isEmpty || components.path == "/",
        components.query == nil
      else {
        throw ConfigError.unsupported(
          name: "BACKUP_S3_ENDPOINT", value: "\(raw) (expected http(s)://host[:port], no path)")
      }

      self.scheme = scheme
      self.host = host
      self.port = components.port
    }
  }

  /// Where one object lives, in the two forms the request needs.
  struct Location: Sendable, Equatable {
    /// The full URL, path already encoded.
    let url: String
    /// The `Host` header, which is signed.
    let host: String
    /// The path before encoding, which the signer encodes the same way the URL is.
    let path: String
  }

  /// The URL and `Host` for `key`, in the configured addressing style.
  func location(of key: String) -> Location {
    let host = pathStyle ? endpoint.authority : "\(bucket).\(endpoint.authority)"
    let path = pathStyle ? "/\(bucket)/\(key)" : "/\(key)"
    return Location(
      url: "\(endpoint.scheme)://\(host)\(SignatureV4.encodePath(path))",
      host: host,
      path: path,
    )
  }

  /// A signed `PutObject` for `body` under `key`.
  ///
  /// Separate from ``putObject(key:body:client:date:)`` so a test can inspect exactly what would
  /// be sent. `x-amz-content-sha256` carries the real payload hash rather than
  /// `UNSIGNED-PAYLOAD`, which makes the store itself reject a body that changed on the way.
  func putObjectRequest(key: String, body: Data, date: Date) -> ClientRequest {
    let location = location(of: key)
    let payloadHash = SignatureV4.sha256Hex(body)

    var signed = [
      "Host": location.host,
      "Content-Type": "application/octet-stream",
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": SignatureV4.timestamp(date),
    ]
    if serverSideEncryption {
      signed["x-amz-server-side-encryption"] = "AES256"
    }

    let signer = SignatureV4(
      accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, region: region, service: "s3")
    let authorization = signer.authorization(
      method: "PUT", path: location.path, headers: signed, payloadHash: payloadHash, date: date)

    // `Host` is set explicitly, and signed, rather than left to the HTTP client. The signature
    // only holds if the header the server checks it against is byte for byte the one signed,
    // whatever the client would have chosen to write for a given port.
    var headers = HTTPHeaders(signed.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    headers.add(name: .authorization, value: authorization)

    return ClientRequest(
      method: .PUT,
      url: URI(string: location.url),
      headers: headers,
      body: ByteBuffer(bytes: body),
    )
  }

  /// Uploads `body` under `key` with one `PutObject`.
  ///
  /// One request, not a multipart upload: a single PUT accepts up to 5 GB, and the dump is about
  /// 120 KB today. Multipart adds three request kinds and cleanup of abandoned parts, for a size
  /// this database is nowhere near. The body is held in memory whole for the same reason; once a
  /// dump reaches hundreds of megabytes, streaming it from the file is the change to make.
  ///
  /// - Throws: ``BackupError/uploadRejected(status:code:message:)`` for any answer but 200, or
  ///   ``BackupError/uploadUnreachable(_:)`` when no answer came back at all.
  func putObject(key: String, body: Data, client: any Client, date: Date) async throws {
    let response: ClientResponse
    do {
      response = try await client.send(putObjectRequest(key: key, body: body, date: date))
    } catch {
      // Transport errors name the host and the failure, never the request's headers, so the
      // signature and everything derived from the secret stay out of the message.
      throw BackupError.uploadUnreachable(String(reflecting: error))
    }

    guard response.status == .ok else {
      let (code, message) = Self.errorDetail(response.body)
      throw BackupError.uploadRejected(
        status: response.status.code, code: code, message: message)
    }
  }

  /// The `<Code>` and `<Message>` of an S3 error document.
  ///
  /// Only those two, on purpose. The document for a signature mismatch also echoes the string to
  /// sign and the access key id, which are no use in an alert and have no business in Slack.
  static func errorDetail(_ body: ByteBuffer?) -> (code: String?, message: String?) {
    guard let body else { return (nil, nil) }
    let text = String(buffer: body)

    func element(_ name: String) -> String? {
      guard let open = text.range(of: "<\(name)>"),
        let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
      else { return nil }
      let value = unescapeXML(
        text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
      return value.isEmpty ? nil : String(value.prefix(300))
    }

    return (element("Code"), element("Message"))
  }

  /// Undoes XML's five predefined escapes, in both their named and numeric forms.
  ///
  /// Stores escape quotes in messages; a region mismatch arrives as
  /// `the region &#34;eu-west-1&#34; is wrong`, which is unreadable in an alert. A full XML
  /// parser for two elements of a short error document was not worth it; FoundationXML also
  /// needs `libxml2` in the runtime image. `&amp;` goes last so an escaped escape stays literal.
  static func unescapeXML(_ text: String) -> String {
    [
      ("&quot;", "\""), ("&#34;", "\""), ("&apos;", "'"), ("&#39;", "'"),
      ("&lt;", "<"), ("&#60;", "<"), ("&gt;", ">"), ("&#62;", ">"),
      ("&amp;", "&"), ("&#38;", "&"),
    ].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
  }
}

extension BackupStorage {
  /// Reads the bucket settings, or nil when `BACKUP_S3_BUCKET` is unset, which disables backups.
  ///
  /// Optional in the way `SlackNotifier.fromEnvironment` is optional: a developer running
  /// `swift run` should not need a bucket. Once a bucket is named, though, every other value is
  /// required and a gap fails the boot. Starting without them would look configured and then
  /// fail every night at 02:00, which is the failure a backup must least be allowed to hide.
  ///
  /// An empty value counts as unset, because the Compose file passes every name through and an
  /// unset variable arrives as an empty string.
  ///
  /// - Parameter environment: The lookup to read from. Tests pass a dictionary so they never
  ///   touch the process environment the rest of the suite shares.
  /// - Throws: ``ConfigError`` for a missing or malformed value.
  static func fromEnvironment(
    _ environment: (String) -> String? = { Environment.get($0) }
  ) throws -> BackupStorage? {
    func value(_ name: String) -> String? {
      environment(name).flatMap { $0.isEmpty ? nil : $0 }
    }
    func required(_ name: String) throws -> String {
      guard let found = value(name) else { throw ConfigError.missing(name) }
      return found
    }
    func flag(_ name: String, default fallback: Bool) throws -> Bool {
      guard let raw = value(name) else { return fallback }
      switch raw.lowercased() {
      case "true", "1", "yes": return true
      case "false", "0", "no": return false
      default: throw ConfigError.unsupported(name: name, value: raw)
      }
    }

    guard let bucket = value("BACKUP_S3_BUCKET") else { return nil }

    return BackupStorage(
      endpoint: try Endpoint(parsing: try required("BACKUP_S3_ENDPOINT")),
      region: try required("BACKUP_S3_REGION"),
      bucket: bucket,
      prefix: normalizedPrefix(value("BACKUP_S3_PREFIX") ?? "insights/"),
      accessKeyID: try required("BACKUP_S3_ACCESS_KEY_ID"),
      secretAccessKey: Secret(try required("BACKUP_S3_SECRET_ACCESS_KEY")),
      pathStyle: try flag("BACKUP_S3_PATH_STYLE", default: true),
      serverSideEncryption: try flag("BACKUP_S3_SSE", default: true),
    )
  }

  /// Drops leading slashes and guarantees a trailing one.
  ///
  /// A leading slash would make every key start with `/`, which S3 keeps as an empty first
  /// segment. A missing trailing slash would run the prefix into the database name, filing
  /// backups under `insightsvapor_database/` rather than `insights/vapor_database/`.
  static func normalizedPrefix(_ raw: String) -> String {
    let trimmed = raw.drop { $0 == "/" }
    guard !trimmed.isEmpty else { return "" }
    return trimmed.hasSuffix("/") ? String(trimmed) : "\(trimmed)/"
  }
}
