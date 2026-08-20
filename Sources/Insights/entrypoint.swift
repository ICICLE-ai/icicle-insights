import Logging
import NIOCore
import NIOPosix
import Vapor

/// Process entry point that configures, executes, and gracefully shuts down Vapor.
@main
enum Entrypoint {
  /// Boots the application and executes the selected Vapor command.
  static func main() async throws {
    var env = try Environment.detect()
    try LoggingSystem.bootstrap(from: &env)

    let app = try await Application.make(env)

    do {
      try await configure(app)
      try await app.execute()
    } catch {
      app.logger.report(error: error)
      try? await app.asyncShutdown()
      throw error
    }
    try await app.asyncShutdown()
  }
}
