import Foundation
import NIOConcurrencyHelpers

/// What a finished child process reported.
struct ProcessOutcome: Sendable, Equatable {
  let exitCode: Int32
  /// Everything it wrote to standard error. May quote connection details; see
  /// `PostgresDumper` for where this is allowed to go.
  let standardError: String
  /// Whether it was stopped for running past its timeout, rather than exiting on its own.
  let timedOut: Bool
}

/// Runs one external program to completion.
///
/// A protocol for the tests' sake alone: the backup job's success, failure and timeout paths are
/// tested against a stub, since CI's Swift image has no `pg_dump` and no database to dump.
/// ``FoundationProcessRunner`` is the only real implementation.
protocol ProcessRunner: Sendable {
  /// Runs `executable`, found on the `PATH` in `environment`, and waits for it.
  ///
  /// - Parameters:
  ///   - executable: A program name, such as `pg_dump`.
  ///   - arguments: Its arguments. Never put a credential here: the arguments of every process
  ///     are readable by anything on the host that can list processes.
  ///   - environment: The child's whole environment. Nothing is inherited implicitly.
  ///   - timeout: How long to wait before stopping it with SIGTERM.
  /// - Throws: When the program cannot be started at all.
  func run(
    _ executable: String,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
  ) async throws -> ProcessOutcome
}

/// Runs programs with Foundation's `Process`.
///
/// Standard error goes to a temporary file, not a pipe. A pipe holds 64 KB; a child that fills
/// it blocks on the write while this side waits for it to exit, and neither moves again. A file
/// cannot fill up that way, and stderr is read only once the child has gone.
///
/// Standard output goes nowhere. A caller that wants the program's output names a file in its
/// arguments, as `pg_dump --file` does.
struct FoundationProcessRunner: ProcessRunner {
  func run(
    _ executable: String,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
  ) async throws -> ProcessOutcome {
    let files = FileManager.default
    let errorURL = files.temporaryDirectory
      .appendingPathComponent("insights-\(UUID().uuidString).stderr")
    guard
      files.createFile(
        atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: errorURL.path])
    }
    defer { try? files.removeItem(at: errorURL) }

    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer { try? errorHandle.close() }

    let process = Process()
    // `env` finds the program on the PATH passed in `environment`, so the caller decides where
    // it comes from and nothing here hard-codes a Debian or Homebrew path.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorHandle

    let watchdog = Watchdog(process)
    let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
        return
      }
      // Armed only once the process is running: `terminate()` on a process that was never
      // launched raises an Objective-C exception on macOS rather than doing nothing.
      watchdog.arm(after: timeout)
    }
    watchdog.disarm()

    let standardError = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
    return ProcessOutcome(
      exitCode: exitCode, standardError: standardError, timedOut: watchdog.fired)
  }
}

/// Stops a process that runs past its timeout, and remembers having done so.
///
/// Without it a `pg_dump` stalled on a dead connection would hold a queue worker's slot forever.
/// Retries cannot rescue that, for the reason `configure` gives about HTTP read timeouts: they
/// fire on failure, and a hang never fails.
private final class Watchdog: @unchecked Sendable {
  // `Process` is not `Sendable`; every touch of it below happens under this lock.
  private let process: Process
  private let state = NIOLockedValueBox<(task: Task<Void, Never>?, fired: Bool)>((nil, false))

  init(_ process: Process) {
    self.process = process
  }

  func arm(after timeout: Duration) {
    let task = Task { [self] in
      guard (try? await Task.sleep(for: timeout)) != nil else { return }
      state.withLockedValue { state in
        // A process that exited in the instant before this woke is not a timeout.
        guard process.isRunning else { return }
        state.fired = true
        process.terminate()
      }
    }
    state.withLockedValue { $0.task = task }
  }

  func disarm() {
    state.withLockedValue { $0.task?.cancel() }
  }

  var fired: Bool {
    state.withLockedValue { $0.fired }
  }
}
