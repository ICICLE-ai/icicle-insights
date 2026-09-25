import Crypto
import Fluent
import Foundation
import Logging
import NIOConcurrencyHelpers
import Queues
import Testing
import Vapor
import XCTQueues

@testable import Insights

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

// MARK: - Fixtures

/// A password that must never appear in an argument list, an alert, or a log line.
private let databasePassword = "db-password-must-not-leak"

/// The database every job test dumps. Nothing connects to it: the process runner is stubbed.
private let dumpTarget = PostgresDumpTarget(
  host: "db.internal",
  port: 5432,
  username: "insights",
  password: Secret(databasePassword),
  database: "test",
  requireTLS: true,
)

/// 2026-09-24T02:00:00Z, the time a scheduled run would stamp.
private let backupDate = Date(timeIntervalSince1970: 1_790_215_200)

/// A stand-in archive and the key a 02:00 run on 2026-09-24 would give it.
private let archive = Data("PGDMP not really an archive".utf8)
private let key = "insights/test/2026/09/test-20260924T020000Z.dump"

/// Bucket settings pointing at a local MinIO-style endpoint, path-style by default.
private func storage(
  endpoint: String = "http://127.0.0.1:9000",
  pathStyle: Bool = true,
  serverSideEncryption: Bool = true,
) throws -> BackupStorage {
  BackupStorage(
    endpoint: try BackupStorage.Endpoint(parsing: endpoint),
    region: "us-east-1",
    bucket: "backups",
    prefix: "insights/",
    accessKeyID: "AKIDTESTONLY",
    secretAccessKey: Secret("test-secret-access-key"),
    pathStyle: pathStyle,
    serverSideEncryption: serverSideEncryption,
  )
}

/// Stands in for `pg_dump`: records how it was called and, on success, writes a canned archive
/// to the path passed in `--file=`, as the real one would.
private struct StubProcessRunner: ProcessRunner {
  struct Invocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
  }

  var outcome = ProcessOutcome(exitCode: 0, standardError: "", timedOut: false)
  var archive = Data("PGDMP fake archive".utf8)
  let invocations = NIOLockedValueBox<[Invocation]>([])

  func run(
    _ executable: String,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
  ) async throws -> ProcessOutcome {
    invocations.withLockedValue {
      $0.append(.init(executable: executable, arguments: arguments, environment: environment))
    }
    if outcome.exitCode == 0, !outcome.timedOut,
      let file = arguments.first(where: { $0.hasPrefix("--file=") })?.dropFirst("--file=".count)
    {
      try archive.write(to: URL(fileURLWithPath: String(file)))
    }
    return outcome
  }

  var recorded: [Invocation] {
    invocations.withLockedValue { $0 }
  }
}

/// Keeps every log line in memory, so a test can prove what did and did not reach the log.
private struct CapturingLogHandler: LogHandler {
  let lines: NIOLockedValueBox<[String]>
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .trace
  var metadataProvider: Logger.MetadataProvider?

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    let rendered = (event.metadata ?? [:]).map { "\($0.key)=\($0.value)" }.sorted()
    lines.withLockedValue { $0.append("\(event.message) \(rendered.joined(separator: " "))") }
  }
}

/// A queue context whose logger is captured, plus the captured lines.
private func capturingContext(for app: Application) -> (QueueContext, NIOLockedValueBox<[String]>) {
  let lines = NIOLockedValueBox<[String]>([])
  let logger = Logger(label: "backup-test") { _ in CapturingLogHandler(lines: lines) }
  let context = QueueContext(
    queueName: .metrics,
    configuration: app.queues.configuration,
    application: app,
    logger: logger,
    on: app.eventLoopGroup.any(),
  )
  return (context, lines)
}

/// Installs a backup with a stubbed `pg_dump` and a store that answers every upload with
/// `status` and `body`. Returns the runner and the recording of HTTP requests.
@discardableResult
private func installBackup(
  on app: Application,
  runner: StubProcessRunner = StubProcessRunner(),
  status: HTTPResponseStatus = .ok,
  body: String = "",
) throws -> (StubProcessRunner, NIOLockedValueBox<[ClientRequest]>) {
  app.databaseBackup = DatabaseBackup(target: dumpTarget, storage: try storage(), runner: runner)
  let requests = stubPagedAPI(on: app) { url in
    guard url.hasPrefix("http://127.0.0.1:9000/backups/insights/test/") else { return nil }
    return ClientResponse(status: status, headers: [:], body: ByteBuffer(string: body))
  }
  return (runner, requests)
}

private func bytes(of request: ClientRequest) -> Data {
  Data(request.body.map { Array($0.readableBytesView) } ?? [])
}

// MARK: - Signature Version 4

/// Checked against the worked examples in AWS's S3 documentation, "Signature Calculations for
/// the Authorization Header: Transferring Payload in a Single Chunk", so a mistake shared by the
/// signer and its tests cannot pass. Every value below is copied from that page.
@Suite("Signature Version 4")
struct SignatureV4Tests {
  private let signer = SignatureV4(
    accessKeyID: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: Secret("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
    region: "us-east-1",
    service: "s3",
  )

  /// 20130524T000000Z, the examples' request time.
  private let date = Date(timeIntervalSince1970: 1_369_353_600)

  private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @Test
  func `The GET Object example signs to AWS's published signature`() {
    let headers = [
      "Host": "examplebucket.s3.amazonaws.com",
      "Range": "bytes=0-9",
      "x-amz-content-sha256": emptyHash,
      "x-amz-date": "20130524T000000Z",
    ]

    let canonical = signer.canonicalRequest(
      method: "GET", path: "/test.txt", headers: headers, payloadHash: emptyHash)
    #expect(
      canonical.request == """
        GET
        /test.txt

        host:examplebucket.s3.amazonaws.com
        range:bytes=0-9
        x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        x-amz-date:20130524T000000Z

        host;range;x-amz-content-sha256;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """)

    #expect(
      signer.stringToSign(canonicalRequest: canonical.request, date: date) == """
        AWS4-HMAC-SHA256
        20130524T000000Z
        20130524/us-east-1/s3/aws4_request
        7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
        """)

    #expect(
      signer.authorization(
        method: "GET", path: "/test.txt", headers: headers, payloadHash: emptyHash, date: date)
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
        + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
        + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
  }

  /// The PUT example also covers path encoding: its key, `test$file.text`, must be signed as
  /// `test%24file.text`.
  @Test
  func `The PUT Object example signs to AWS's published signature`() {
    let payload = Data("Welcome to Amazon S3.".utf8)
    let payloadHash = SignatureV4.sha256Hex(payload)
    #expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")

    let headers = [
      "Host": "examplebucket.s3.amazonaws.com",
      "Date": "Fri, 24 May 2013 00:00:00 GMT",
      "x-amz-date": "20130524T000000Z",
      "x-amz-storage-class": "REDUCED_REDUNDANCY",
      "x-amz-content-sha256": payloadHash,
    ]

    let canonical = signer.canonicalRequest(
      method: "PUT", path: "/test$file.text", headers: headers, payloadHash: payloadHash)
    #expect(
      canonical.request == """
        PUT
        /test%24file.text

        date:Fri, 24 May 2013 00:00:00 GMT
        host:examplebucket.s3.amazonaws.com
        x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
        x-amz-date:20130524T000000Z
        x-amz-storage-class:REDUCED_REDUNDANCY

        date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
        44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
        """)

    #expect(
      signer.stringToSign(canonicalRequest: canonical.request, date: date).hasSuffix(
        "9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))

    #expect(
      signer.authorization(
        method: "PUT", path: "/test$file.text", headers: headers, payloadHash: payloadHash,
        date: date)
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
        + "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,"
        + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
  }

  @Test
  func `Timestamps are UTC in the basic ISO 8601 form`() {
    #expect(SignatureV4.timestamp(date) == "20130524T000000Z")
    #expect(SignatureV4.timestamp(backupDate) == "20260924T020000Z")
    #expect(SignatureV4.dateStamp(backupDate) == "20260924")
  }

  @Test
  func `Paths keep slashes and encode everything outside the unreserved set`() {
    #expect(
      SignatureV4.encodePath("/b/insights/a b+c/ü~._-.dump")
        == "/b/insights/a%20b%2Bc/%C3%BC~._-.dump")
  }
}

// MARK: - The upload request

@Suite("Backup upload request", .serialized)
struct BackupUploadTests {

  @Test
  func `A path-style upload is a signed PUT to endpoint, bucket, then key`() async throws {
    try await withInsightsApp { app in
      let requests = stubPagedAPI(on: app) { url in
        url == "http://127.0.0.1:9000/backups/\(key)" ? ClientResponse(status: .ok) : nil
      }

      try await storage().putObject(key: key, body: archive, client: app.client, date: backupDate)

      let request = try #require(requests.withLockedValue { $0 }.first)
      #expect(request.method == .PUT)
      #expect(request.url.string == "http://127.0.0.1:9000/backups/\(key)")
      #expect(request.headers.first(name: .host) == "127.0.0.1:9000")
      #expect(request.headers.first(name: "x-amz-date") == "20260924T020000Z")
      #expect(request.headers.first(name: "x-amz-server-side-encryption") == "AES256")
      #expect(request.headers.first(name: .contentType) == "application/octet-stream")

      // The body hash is the real one, recomputed here with Crypto directly rather than through
      // the helper the code under test uses.
      let expectedHash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
      #expect(request.headers.first(name: "x-amz-content-sha256") == expectedHash)
      #expect(bytes(of: request) == archive)

      let authorization = try #require(request.headers.first(name: .authorization))
      #expect(
        authorization.hasPrefix(
          "AWS4-HMAC-SHA256 Credential=AKIDTESTONLY/20260924/us-east-1/s3/aws4_request,"
            + "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;"
            + "x-amz-server-side-encryption,Signature="))
      #expect(!authorization.contains("test-secret-access-key"))
    }
  }

  @Test
  func `A virtual-hosted upload puts the bucket in the host name`() async throws {
    try await withInsightsApp { app in
      let url = "https://backups.s3.us-east-2.amazonaws.com/\(key)"
      let requests = stubPagedAPI(on: app) { $0 == url ? ClientResponse(status: .ok) : nil }

      try await storage(endpoint: "https://s3.us-east-2.amazonaws.com", pathStyle: false)
        .putObject(key: key, body: archive, client: app.client, date: backupDate)

      let request = try #require(requests.withLockedValue { $0 }.first)
      #expect(request.url.string == url)
      #expect(request.headers.first(name: .host) == "backups.s3.us-east-2.amazonaws.com")
    }
  }

  @Test
  func `Server-side encryption can be turned off, and is then neither sent nor signed`() throws {
    let request = try storage(serverSideEncryption: false)
      .putObjectRequest(key: key, body: archive, date: backupDate)

    #expect(request.headers.first(name: "x-amz-server-side-encryption") == nil)
    #expect(
      request.headers.first(name: .authorization)?.contains(
        "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,") == true)
  }

  @Test
  func `A refusal carries the store's code and message, and nothing else from the body`()
    async throws
  {
    try await withInsightsApp { app in
      stubPagedAPI(on: app) { _ in
        ClientResponse(
          status: .forbidden, headers: [:],
          body: ByteBuffer(
            string: """
              <?xml version="1.0" encoding="UTF-8"?>
              <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we \
              calculated does not match the signature you provided.</Message>\
              <AWSAccessKeyId>AKIDTESTONLY</AWSAccessKeyId>\
              <StringToSign>AWS4-HMAC-SHA256 …</StringToSign></Error>
              """))
      }

      let error = await #expect(throws: BackupError.self) {
        try await storage().putObject(
          key: key, body: archive, client: app.client, date: backupDate)
      }

      guard case .uploadRejected(let status, let code, let message) = error else {
        Issue.record("Expected uploadRejected, got \(String(describing: error))")
        return
      }
      #expect(status == 403)
      #expect(code == "SignatureDoesNotMatch")
      #expect(message?.hasPrefix("The request signature we calculated") == true)
      #expect(error?.reason.contains("AKIDTESTONLY") == false)
      #expect(error?.reason.contains("StringToSign") == false)
    }
  }

  /// What a real gateway sent for a wrong `BACKUP_S3_REGION` during the end-to-end check, escapes
  /// and all.
  @Test
  func `Escaped quotes in a store's message are made readable`() {
    let (code, message) = BackupStorage.errorDetail(
      ByteBuffer(
        string: "<Error><Code>AuthorizationHeaderMalformed</Code><Message>The authorization "
          + "header is malformed; the region &#34;eu-west-1&#34; is wrong; expecting "
          + "&#34;us-east-1&#34;</Message></Error>"))

    #expect(code == "AuthorizationHeaderMalformed")
    #expect(
      message == "The authorization header is malformed; "
        + #"the region "eu-west-1" is wrong; expecting "us-east-1""#)
    #expect(BackupStorage.unescapeXML("a &amp;quot; b &lt;c&gt;") == "a &quot; b <c>")
  }
}

// MARK: - The job

@Suite("Database backup job", .serialized)
struct DatabaseBackupJobTests {
  private let payload = DatabaseBackupRequest(requestedAt: backupDate)

  @Test
  func `The object key is prefix, database, year, month, then a UTC timestamp`() throws {
    let backup = DatabaseBackup(
      target: dumpTarget, storage: try storage(), runner: StubProcessRunner())
    #expect(backup.objectKey(at: backupDate) == "insights/test/2026/09/test-20260924T020000Z.dump")
  }

  @Test
  func `pg_dump gets the password in its environment, never its arguments`() {
    let arguments = dumpTarget.arguments(file: "/tmp/out.dump")
    #expect(
      arguments == [
        "--format=custom", "--no-password", "--lock-wait-timeout=60s", "--host=db.internal",
        "--port=5432", "--username=insights", "--dbname=test", "--file=/tmp/out.dump",
      ])
    #expect(!arguments.joined().contains(databasePassword))

    // Exactly these keys: nothing else from this process's environment is handed to the child.
    let environment = dumpTarget.environment(path: "/usr/bin")
    #expect(
      environment == [
        "PGPASSWORD": databasePassword,
        "PGSSLMODE": "require",
        "PGCONNECT_TIMEOUT": "10",
        "PGAPPNAME": "insights-backup",
        "PATH": "/usr/bin",
      ])
  }

  @Test
  func `DATABASE_TLS=disable reaches pg_dump as PGSSLMODE=disable`() {
    let local = PostgresDumpTarget(
      host: "127.0.0.1", port: 5432, username: "u", password: Secret("p"), database: "test",
      requireTLS: false)
    #expect(local.environment(path: nil)["PGSSLMODE"] == "disable")
  }

  @Test
  func `A successful run uploads exactly what pg_dump wrote, and alerts nobody`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let (runner, requests) = try installBackup(on: app)
      let (context, lines) = capturingContext(for: app)

      try await BackupDatabase().dequeue(context, payload)

      let invocation = try #require(runner.recorded.first)
      #expect(runner.recorded.count == 1)
      #expect(invocation.executable == "pg_dump")
      #expect(invocation.environment["PGPASSWORD"] == databasePassword)

      let request = try #require(requests.withLockedValue { $0 }.first)
      #expect(request.method == .PUT)
      #expect(request.url.string.hasPrefix("http://127.0.0.1:9000/backups/insights/test/"))
      #expect(request.url.string.hasSuffix("Z.dump"))
      #expect(bytes(of: request) == runner.archive)
      #expect(
        request.headers.first(name: "x-amz-content-sha256")
          == SHA256.hash(data: runner.archive).map { String(format: "%02x", $0) }.joined())

      #expect(notifier.recorded.isEmpty)
      #expect(try await JobFailure.query(on: app.db).count() == 0)

      let success = try #require(
        lines.withLockedValue { $0 }.first { $0.hasPrefix("Database backup uploaded.") })
      #expect(success.contains("bytes=\(runner.archive.count)"))
      #expect(success.contains("key=insights/test/"))

      // The temporary archive is gone once the job returns.
      let file = try #require(invocation.arguments.first { $0.hasPrefix("--file=") })
      #expect(!FileManager.default.fileExists(atPath: String(file.dropFirst("--file=".count))))
    }
  }

  /// pg_dump's standard error can quote connection details, so it goes to the log, scrubbed of
  /// the password, and never into the thrown error, the alert or `job_failures`.
  @Test
  func `A failing pg_dump uploads nothing and keeps its stderr out of the alert`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let stderr =
        "pg_dump: error: connection to server at \"db.internal\" failed: "
        + "FATAL: password authentication failed (tried \(databasePassword))"
      let (_, requests) = try installBackup(
        on: app,
        runner: StubProcessRunner(
          outcome: ProcessOutcome(exitCode: 1, standardError: stderr, timedOut: false)))
      let (context, lines) = capturingContext(for: app)

      let error = await #expect(throws: BackupError.self) {
        try await BackupDatabase().dequeue(context, payload)
      }
      #expect(requests.withLockedValue { $0 }.isEmpty)

      let thrown = try #require(error)
      #expect(!String(describing: thrown).contains("password authentication failed"))
      try await BackupDatabase().error(context, thrown, payload)

      let alert = try #require(notifier.recorded.first)
      #expect(notifier.recorded.count == 1)
      #expect(alert.severity == .warning)
      #expect(alert.identifier == "backup_failed")
      #expect(alert.job == "BackupDatabase")
      #expect(alert.subject == "test")
      #expect(alert.details.contains("exited with status 1"))
      #expect(!alert.details.contains("password authentication failed"))
      #expect(!alert.details.contains(databasePassword))

      let failure = try #require(try await JobFailure.query(on: app.db).first())
      #expect(failure.identifier == "backup_failed")
      #expect(failure.severity == "warning")
      #expect(failure.$resource.id == nil)
      #expect(!failure.details.contains("password authentication failed"))

      // The diagnosis does reach the log, with the password scrubbed out of it.
      let logged = lines.withLockedValue { $0 }
      #expect(logged.contains { $0.contains("password authentication failed") })
      #expect(!logged.contains { $0.contains(databasePassword) })
    }
  }

  @Test
  func `A refused upload alerts with the store's reason`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      try installBackup(
        on: app, status: .forbidden,
        body: "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
      let context = queueContext(for: app)

      let error = await #expect(throws: BackupError.self) {
        try await BackupDatabase().dequeue(context, payload)
      }
      try await BackupDatabase().error(context, try #require(error), payload)

      let alert = try #require(notifier.recorded.first)
      #expect(alert.identifier == "backup_failed")
      #expect(alert.details.contains("status 403 AccessDenied: Access Denied"))
      #expect(alert.details.contains("BACKUP_S3_SECRET_ACCESS_KEY"))
      #expect(!alert.details.contains("test-secret-access-key"))
    }
  }

  /// One alert per six hours for the same missed backup, however many times it is reported;
  /// every report is still stored.
  @Test
  func `Repeated failures alert once and are all recorded`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      let context = queueContext(for: app)

      await context.reportBackupFailure(BackupError.emptyDump, job: BackupDatabase.name)
      await context.reportBackupFailure(BackupError.emptyDump, job: BackupDatabase.name)

      // Bound first: a closure whose only `try` sits inside a macro is inferred non-throwing.
      let recorded = try await JobFailure.query(on: app.db).count()
      #expect(notifier.recorded.count == 1)
      #expect(recorded == 2)
    }
  }

  @Test
  func `The daily schedule queues one backup on metrics, with a small retry budget`()
    async throws
  {
    try await withQueueApp { app in
      let (_, requests) = try installBackup(on: app)

      try await ScheduleDatabaseBackup().run(context: queueContext(for: app))

      #expect(app.queues.asyncTest.all(BackupDatabase.self).count == 1)
      let queued = try #require(app.queues.asyncTest.jobs.values.first)
      #expect(queued.maxRetryCount == backupMaxRetryCount)
      #expect(queued.jobName == BackupDatabase.name)

      // Through the worker, as production takes it: the job is registered under its name and its
      // payload survives the queue's encoding.
      try await app.queues.queue(.metrics).worker.run()
      #expect(requests.withLockedValue { $0 }.count == 1)
      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  @Test
  func `With no bucket configured the schedule queues nothing`() async throws {
    try await withQueueApp { app in
      // The suite's own environment names no bucket, so configure left backups off.
      #expect(app.databaseBackup == nil)

      try await ScheduleDatabaseBackup().run(context: queueContext(for: app))

      #expect(app.queues.asyncTest.queue.isEmpty)
    }
  }

  /// The scheduler had a bucket and this worker did not. Retrying cannot fix that, so it is
  /// reported once and the job returns.
  @Test
  func `A worker with no bucket reports the mismatch instead of throwing`() async throws {
    try await withInsightsApp { app in
      let notifier = stubNotifier(on: app)
      #expect(app.databaseBackup == nil)

      try await BackupDatabase().dequeue(queueContext(for: app), payload)

      let alert = try #require(notifier.recorded.first)
      #expect(alert.identifier == "backup_failed")
      #expect(alert.details.contains("no BACKUP_S3_BUCKET"))
    }
  }
}

// MARK: - Configuration

@Suite("Backup configuration")
struct BackupConfigurationTests {
  private let complete = [
    "BACKUP_S3_ENDPOINT": "https://s3.us-east-2.amazonaws.com",
    "BACKUP_S3_REGION": "us-east-2",
    "BACKUP_S3_BUCKET": "icicle-backups",
    "BACKUP_S3_ACCESS_KEY_ID": "AKIDEXAMPLE",
    "BACKUP_S3_SECRET_ACCESS_KEY": "not-a-real-secret",
  ]

  private func read(_ values: [String: String]) throws -> BackupStorage? {
    try BackupStorage.fromEnvironment { values[$0] }
  }

  @Test
  func `No bucket, or an empty one, disables backups`() throws {
    #expect(try read([:]) == nil)
    var empty = complete
    empty["BACKUP_S3_BUCKET"] = ""
    #expect(try read(empty) == nil)
  }

  @Test
  func `Defaults are the insights prefix, path-style, and encryption on`() throws {
    let storage = try #require(try read(complete))
    #expect(storage.prefix == "insights/")
    #expect(storage.pathStyle)
    #expect(storage.serverSideEncryption)
    #expect(
      storage.endpoint
        == (try BackupStorage.Endpoint(parsing: "https://s3.us-east-2.amazonaws.com")))
    // Redacted wherever it is printed.
    #expect("\(storage.secretAccessKey)" == "«redacted»")
  }

  @Test(arguments: [
    "BACKUP_S3_ENDPOINT", "BACKUP_S3_REGION", "BACKUP_S3_ACCESS_KEY_ID",
    "BACKUP_S3_SECRET_ACCESS_KEY",
  ])
  func `A bucket without the rest fails the boot`(missing: String) {
    var values = complete
    values[missing] = nil
    #expect(throws: ConfigError.self) { try read(values) }
  }

  @Test
  func `Flags read true and false in the usual spellings, and refuse anything else`() throws {
    var values = complete
    values["BACKUP_S3_PATH_STYLE"] = "false"
    values["BACKUP_S3_SSE"] = "0"
    let storage = try #require(try read(values))
    #expect(!storage.pathStyle)
    #expect(!storage.serverSideEncryption)

    values["BACKUP_S3_SSE"] = "maybe"
    #expect(throws: ConfigError.self) { try read(values) }
  }

  @Test(arguments: ["s3.amazonaws.com", "ftp://host", "https://ceph.example.org/s3"])
  func `An endpoint must be a bare http or https origin`(endpoint: String) {
    var values = complete
    values["BACKUP_S3_ENDPOINT"] = endpoint
    #expect(throws: ConfigError.self) { try read(values) }
  }

  @Test(arguments: [
    ("insights/", "insights/"), ("insights", "insights/"), ("/nightly/db/", "nightly/db/"),
    ("/", ""),
  ])
  func `The prefix gains a trailing slash and loses a leading one`(raw: String, expected: String) {
    #expect(BackupStorage.normalizedPrefix(raw) == expected)
  }
}

// MARK: - The real process runner

/// Runs `sh` and `sleep`, which both the macOS host and CI's Swift image have, to prove the
/// runner reports what the backup code relies on: the exit status, standard error, and a stop
/// on timeout.
@Suite("Foundation process runner", .serialized)
struct FoundationProcessRunnerTests {
  private let environment = ["PATH": "/usr/bin:/bin"]

  @Test
  func `The exit status and standard error come back`() async throws {
    let outcome = try await FoundationProcessRunner().run(
      "sh", arguments: ["-c", "printf 'went wrong' >&2; exit 3"], environment: environment,
      timeout: .seconds(30))

    #expect(outcome == ProcessOutcome(exitCode: 3, standardError: "went wrong", timedOut: false))
  }

  /// Only what is passed reaches the child. `HOME` is set in every test process, so it stands in
  /// for what this process holds and `pg_dump` has no use for, such as the Tapis token.
  @Test
  func `The child sees only the environment it is given`() async throws {
    let outcome = try await FoundationProcessRunner().run(
      "sh", arguments: ["-c", "printf '%s' \"${HOME-unset}\" >&2"], environment: environment,
      timeout: .seconds(30))

    #expect(outcome.standardError == "unset")
  }

  @Test
  func `A process past its timeout is stopped and reported as timed out`() async throws {
    let started = ContinuousClock.now
    let outcome = try await FoundationProcessRunner().run(
      "sleep", arguments: ["30"], environment: environment, timeout: .milliseconds(300))

    #expect(outcome.timedOut)
    #expect(outcome.exitCode != 0)
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  /// The worker runs with SIGTERM ignored, because `QueuesCommand` takes over that signal to drain
  /// on shutdown, and a child inherits an ignored signal. `Process.terminate()` sends SIGTERM, so
  /// under these conditions it stopped nothing and a hung `pg_dump` ran on forever. The timeout
  /// has to stop the child anyway.
  ///
  /// Serialized with its suite, and the disposition restored, because a signal disposition is
  /// process-wide.
  @Test
  func `A timeout stops the process even when SIGTERM is ignored, as in the worker`() async throws {
    let previous = signal(SIGTERM, SIG_IGN)
    defer { signal(SIGTERM, previous) }

    let started = ContinuousClock.now
    let outcome = try await FoundationProcessRunner().run(
      "sleep", arguments: ["30"], environment: environment, timeout: .milliseconds(300))

    #expect(outcome.timedOut)
    #expect(outcome.exitCode != 0)
    #expect(ContinuousClock.now - started < .seconds(10))
  }
}
