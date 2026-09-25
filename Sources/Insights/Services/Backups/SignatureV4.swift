import Crypto
import Foundation

/// AWS Signature Version 4, for the one S3 request this service makes: a backup's `PutObject`.
///
/// Written here rather than taken from an SDK. Soto, the Swift AWS SDK, was rejected because it
/// brings hundreds of generated files to compile for a single signed PUT, and compile time is
/// already the slowest part of CI. The algorithm itself is small and fixed, and the tests check
/// it against the worked examples AWS publishes, not against itself.
///
/// Deliberately narrower than the full specification. There is no query-string canonicalisation,
/// because `PutObject` sends none, and no chunked or unsigned payloads, because a backup is signed
/// whole with its SHA-256. Anything that needs those should revisit the decision above first.
struct SignatureV4: Sendable {
  /// The signing algorithm named in the `Authorization` header and the string to sign.
  static let algorithm = "AWS4-HMAC-SHA256"

  let accessKeyID: String
  let secretAccessKey: Secret
  /// The bucket's region, such as `us-east-2`. S3-compatible services that ignore regions still
  /// expect one in the signature, usually `us-east-1`.
  let region: String
  /// Always `s3` here; a parameter only so the credential scope reads as the specification does.
  let service: String

  /// The request's `Authorization` header value.
  ///
  /// - Parameters:
  ///   - method: The HTTP method, such as `PUT`.
  ///   - path: The request path before encoding, starting with `/`. Each segment is encoded once,
  ///     as S3 expects; S3 is the one AWS service whose canonical path is not double-encoded.
  ///   - headers: Every header to sign, including `host`, `x-amz-date` and
  ///     `x-amz-content-sha256`. Each one must be sent exactly as given.
  ///   - payloadHash: Lowercase hex SHA-256 of the body, the value of `x-amz-content-sha256`.
  ///   - date: The instant in `x-amz-date`.
  func authorization(
    method: String,
    path: String,
    headers: [String: String],
    payloadHash: String,
    date: Date,
  ) -> String {
    let canonical = canonicalRequest(
      method: method, path: path, headers: headers, payloadHash: payloadHash)
    let signature = signature(
      stringToSign: stringToSign(canonicalRequest: canonical.request, date: date), date: date)

    return "\(Self.algorithm) Credential=\(accessKeyID)/\(credentialScope(date)),"
      + "SignedHeaders=\(canonical.signedHeaders),Signature=\(signature)"
  }

  /// Step 1: the canonical request, and the signed-header list it ends with.
  ///
  /// The query line is always empty. See the type's summary for why.
  func canonicalRequest(
    method: String,
    path: String,
    headers: [String: String],
    payloadHash: String,
  ) -> (request: String, signedHeaders: String) {
    // Lowercased, trimmed, and inner runs of spaces collapsed: the specification's "Trimall".
    // Sorted by name, which is also the order the signed-header list must use.
    let canonicalHeaders = headers.map { name, value in
      (
        name.lowercased(),
        value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
      )
    }.sorted { $0.0 < $1.0 }

    let signedHeaders = canonicalHeaders.map(\.0).joined(separator: ";")
    let request = [
      method,
      Self.encodePath(path),
      "",
      canonicalHeaders.map { "\($0.0):\($0.1)\n" }.joined(),
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")

    return (request, signedHeaders)
  }

  /// Step 2: what the derived key signs.
  func stringToSign(canonicalRequest: String, date: Date) -> String {
    [
      Self.algorithm,
      Self.timestamp(date),
      credentialScope(date),
      Self.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
  }

  /// Steps 3 and 4: derives the day's signing key from the secret, then signs.
  ///
  /// The secret is read here and nowhere else, and only ever as HMAC key material.
  func signature(stringToSign: String, date: Date) -> String {
    var key = SymmetricKey(data: Data("AWS4\(secretAccessKey.getSecretValue())".utf8))
    for part in [Self.dateStamp(date), region, service, "aws4_request"] {
      key = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key))
    }
    return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
  }

  /// `yyyyMMdd/region/service/aws4_request`.
  private func credentialScope(_ date: Date) -> String {
    "\(Self.dateStamp(date))/\(region)/\(service)/aws4_request"
  }

  // MARK: - Encoding

  /// ISO 8601 basic format in UTC, `20130524T000000Z`: the `x-amz-date` value.
  ///
  /// Built from calendar components on `UTCDay.calendar` rather than a `DateFormatter`, which
  /// would follow the process locale and time zone unless every property were pinned.
  static func timestamp(_ date: Date) -> String {
    let parts = UTCDay.calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02dT%02d%02d%02dZ",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
    )
  }

  /// The `yyyyMMdd` that opens the credential scope.
  static func dateStamp(_ date: Date) -> String {
    String(timestamp(date).prefix(8))
  }

  /// Lowercase hex SHA-256, the form both `x-amz-content-sha256` and the string to sign use.
  static func sha256Hex(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  /// Lowercase hex of any digest or MAC.
  static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Percent-encodes every byte outside RFC 3986's unreserved set, segment by segment.
  ///
  /// `/` is kept as the separator. This is the encoding both the request URL and the canonical
  /// request use, so the two cannot disagree about a key.
  static func encodePath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
      .map { segment in
        segment.utf8.map { byte in
          switch byte {
          case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
            UInt8(ascii: "_"), UInt8(ascii: "~"):
            String(UnicodeScalar(byte))
          default:
            String(format: "%%%02X", byte)
          }
        }.joined()
      }
      .joined(separator: "/")
  }
}
