import Fluent
import Redis
import Vapor
import VaporToOpenAPI

/// Liveness and readiness probes for the container orchestrator.
///
/// Mounted at the root rather than under `/api`, and deliberately outside the rate limiter: the
/// kubelet polls these every few seconds from a single address, which is exactly the traffic
/// shape a per-IP ceiling is built to refuse. A throttled probe reads as a dead pod.
struct HealthController: RouteCollection {
  /// Mounts `/health` and `/ready`.
  func boot(routes: any RoutesBuilder) throws {
    routes.get("health", use: live).excludeFromOpenAPI()
    routes.get("ready", use: ready).excludeFromOpenAPI()
  }

  /// Reports that the process is running.
  ///
  /// Checks nothing else, on purpose. Liveness failure gets the pod killed, so anything that can
  /// fail transiently must stay out of it — a brief database blip should not restart a server
  /// that would have recovered on its own. Dependencies belong in ``ready(req:)``.
  @Sendable
  func live(req: Request) async throws -> Status {
    Status(status: "ok")
  }

  /// Reports whether this instance can currently serve traffic.
  ///
  /// Readiness failure removes the pod from the load balancer without restarting it, which is the
  /// right response to a dependency being unreachable. Both backing services are checked because
  /// losing either one degrades the API: Postgres holds everything served, and Valkey holds the
  /// rate limit counters and the queues.
  @Sendable
  func ready(req: Request) async throws -> Status {
    do {
      // A count over `admins` rather than `SELECT 1`: it costs the same against a table bounded
      // by the number of people who administer this deployment, and it additionally proves the
      // schema exists. A server whose migrations have not run is not ready to serve.
      _ = try await Admin.query(on: req.db).count()
    } catch {
      req.logger.error(
        "Readiness probe failed: database unreachable.",
        metadata: ["error": .string("\(error)")]
      )
      throw Abort(.serviceUnavailable, reason: "Database unavailable.")
    }

    do {
      _ = try await req.redis.ping().get()
    } catch {
      req.logger.error(
        "Readiness probe failed: Redis unreachable.",
        metadata: ["error": .string("\(error)")]
      )
      throw Abort(.serviceUnavailable, reason: "Redis unavailable.")
    }

    return Status(status: "ready")
  }

  /// Probe response body. Orchestrators read the status code; this is for humans running `curl`.
  struct Status: Content {
    let status: String
  }
}
