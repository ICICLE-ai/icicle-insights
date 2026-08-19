import Fluent
import Foundation
import JWT
import JWTKit
import Redis
import Testing
import Vapor
import VaporTesting

@testable import Insights

/// CORS, rate limits, response headers, live key rotation, and the admins table.
///
/// Serialized because several of these configure through the process environment, which
/// `configure` reads at boot — so they cannot safely overlap.
@Suite("Hardening", .serialized)
struct HardeningTests {

  // MARK: - Security headers

  @Test
  func `Security headers are present on a success`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(res.headers.first(name: .xContentTypeOptions) == "nosniff")
          #expect(res.headers.first(name: "Referrer-Policy") == "strict-origin-when-cross-origin")
          #expect(res.headers.first(name: .xFrameOptions) == "DENY")
        },
      )
    }
  }

  @Test
  func `Security headers survive an error response`() async throws {
    try await withInsightsApp { app in
      // The regression worth guarding: headers are stamped on the way out, so a middleware
      // registered after ErrorMiddleware would never see this response at all.
      try await app.testing().test(
        .GET,
        "api/vaults",
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
          #expect(res.headers.first(name: .xContentTypeOptions) == "nosniff")
          #expect(res.headers.first(name: .xFrameOptions) == "DENY")
        },
      )
    }
  }

  @Test
  func `HSTS is withheld outside production`() async throws {
    try await withInsightsApp { app in
      // Pinning localhost to HTTPS in a developer's browser is unpleasant to undo.
      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(res.headers.first(name: .strictTransportSecurity) == nil)
        },
      )
    }
  }

  // MARK: - CORS

  @Test
  func `An allowed origin gets CORS headers, including on errors`() async throws {
    setenv("CORS_ORIGINS", "https://icicle.example.org", 1)
    defer { unsetenv("CORS_ORIGINS") }

    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        headers: ["Origin": "https://icicle.example.org"],
        afterResponse: { res async throws in
          #expect(
            res.headers.first(name: "Access-Control-Allow-Origin")
              == "https://icicle.example.org")
        },
      )

      // The ordering guarantee: a browser can only read the reason for a 401 if the 401 itself
      // carries the CORS headers.
      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: ["Origin": "https://icicle.example.org"],
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
          #expect(
            res.headers.first(name: "Access-Control-Allow-Origin")
              == "https://icicle.example.org")
        },
      )
    }
  }

  @Test
  func `An origin outside the allowlist gets nothing`() async throws {
    setenv("CORS_ORIGINS", "https://icicle.example.org", 1)
    defer { unsetenv("CORS_ORIGINS") }

    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        headers: ["Origin": "https://not-us.example.org"],
        afterResponse: { res async throws in
          let allowed = res.headers.first(name: "Access-Control-Allow-Origin")
          #expect(allowed == nil || allowed?.isEmpty == true)
        },
      )
    }
  }

  @Test
  func `CORS is absent when unconfigured`() async throws {
    unsetenv("CORS_ORIGINS")

    try await withInsightsApp { app in
      // A same-origin deployment should carry no CORS surface at all.
      try await app.testing().test(
        .GET,
        "api/resources",
        headers: ["Origin": "https://anywhere.example.org"],
        afterResponse: { res async throws in
          #expect(res.headers.first(name: "Access-Control-Allow-Origin") == nil)
        },
      )
    }
  }

  // MARK: - Rate limiting

  @Test
  func `A webhook token is limited per token`() async throws {
    setenv("WEBHOOK_RATE_LIMIT_PER_MINUTE", "2", 1)
    defer { unsetenv("WEBHOOK_RATE_LIMIT_PER_MINUTE") }

    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      for expected in [HTTPStatus.created, .created, .tooManyRequests] {
        try await app.testing().test(
          .POST,
          "api/resources/\(resourceID)/metrics",
          headers: bearer(issued.token),
          beforeRequest: { req in
            try req.content.encode(Metric.CreateForResource(reading: 1, type: .downloads))
          },
          afterResponse: { res async throws in
            #expect(res.status == expected)
            if expected == .tooManyRequests {
              #expect(res.headers.first(name: .retryAfter) != nil)
            }
          },
        )
      }

      // Refused, not silently dropped: two readings landed, the third did not.
      #expect(try await Metric.query(on: app.db).count() == 2)
    }
  }

  @Test
  func `A different token has its own budget`() async throws {
    setenv("WEBHOOK_RATE_LIMIT_PER_MINUTE", "1", 1)
    defer { unsetenv("WEBHOOK_RATE_LIMIT_PER_MINUTE") }

    try await withInsightsApp { app in
      let account = try await makeAccount(on: app.db)
      let first = try await makeResource(on: app.db, accountID: try account.requireID())
      let second = try await makeResource(
        on: app.db, accountID: try account.requireID(), name: "other")

      let one = try await issueWebhookToken(on: app, resourceID: try first.requireID())
      let two = try await issueWebhookToken(on: app, resourceID: try second.requireID())

      // One runaway service must not exhaust everyone else's quota, which is why the counter
      // keys on the token rather than the address they may share.
      for (token, resource) in [(one, first), (two, second)] {
        try await app.testing().test(
          .POST,
          "api/resources/\(try resource.requireID())/metrics",
          headers: bearer(token.token),
          beforeRequest: { req in
            try req.content.encode(Metric.CreateForResource(reading: 1, type: .downloads))
          },
          afterResponse: { res async throws in #expect(res.status == .created) },
        )
      }
    }
  }

  @Test
  func `An unreachable counter store still serves traffic`() async throws {
    try await withInsightsApp(setUp: { app in
      // Nothing listens here. A limiter that fails closed would take the whole API down with
      // its counter store, which is worse than the abuse it exists to prevent.
      app.redis.configuration = try RedisConfiguration(hostname: "127.0.0.1", port: 6399)
    }) { app in
      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()
      let issued = try await issueWebhookToken(on: app, resourceID: resourceID)

      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(issued.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 3, type: .downloads))
        },
        afterResponse: { res async throws in
          #expect(res.status == .created)
        },
      )
    }
  }

  // MARK: - Signing key rotation

  @Test
  func `Rotation keeps previously issued tokens working`() async throws {
    try await withInsightsApp { app in
      let secrets = InMemorySecrets([
        ServiceTokenSigningKey.secretName:
          try ServiceTokenSigningKey.encode(ServiceTokenSigningKey.initial())
      ])
      app.secrets = secrets
      try await app.loadServiceTokenKeys(from: secrets)

      let account = try await makeAccount(on: app.db)
      let resource = try await makeResource(on: app.db, accountID: try account.requireID())
      let resourceID = try resource.requireID()

      let before = try await issueWebhookToken(on: app, resourceID: resourceID, label: "before")
      let oldKid = app.activeSigningKid

      let newKid = try await app.rotateServiceTokenKey(using: secrets)
      #expect(newKid != oldKid)
      #expect(app.activeSigningKid == newKid)

      // The point of keeping retired keys registered: rotating must not take every deployed
      // service offline at once.
      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(before.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 1, type: .downloads))
        },
        afterResponse: { res async throws in #expect(res.status == .created) },
      )

      // And a token minted after the rotation works too — both keys are live.
      let after = try await issueWebhookToken(on: app, resourceID: resourceID, label: "after")
      try await app.testing().test(
        .POST,
        "api/resources/\(resourceID)/metrics",
        headers: bearer(after.token),
        beforeRequest: { req in
          try req.content.encode(Metric.CreateForResource(reading: 2, type: .downloads))
        },
        afterResponse: { res async throws in #expect(res.status == .created) },
      )
    }
  }

  @Test
  func `Rotation retires the oldest keys rather than growing forever`() async throws {
    try await withInsightsApp { app in
      let secrets = InMemorySecrets([
        ServiceTokenSigningKey.secretName:
          try ServiceTokenSigningKey.encode(ServiceTokenSigningKey.initial())
      ])
      app.secrets = secrets

      for _ in 0..<5 {
        _ = try await app.rotateServiceTokenKey(using: secrets)
      }

      let keyset = try ServiceTokenSigningKey.decode(
        try await secrets.readSecret(named: ServiceTokenSigningKey.secretName))

      #expect(keyset.keys.count == ServiceTokenSigningKey.maxRetainedKeys)
      #expect(keyset.active == keyset.keys.first?.kid)
    }
  }

  // MARK: - Tenant key

  @Test
  func `An unwrapped tenant PEM still parses`() async throws {
    try await withInsightsApp { app in
      // Tapis returns the base64 body as one long line. RFC 7468 wants 64-character lines and
      // SwiftASN1 enforces it, so the key has to be re-wrapped before it will parse at all —
      // without this, every production boot dies on `invalidPEMDocument`. Only a real boot
      // caught it, because `.testing` skips the fetch entirely.
      let unwrapped =
        TestKeys.publicPEMBody.replacingOccurrences(of: "\n", with: "")
      let json = """
        {"result":{"public_key":"-----BEGIN PUBLIC KEY-----\\n\(unwrapped)\\n-----END PUBLIC KEY-----"}}
        """

      // Derived rather than written out: the stub matches on path, and `TAPIS_BASE_URL` carries
      // a prefix that differs between environments.
      let path = URI(
        string: "\(app.tapisConfig.tenantsBaseURL)/\(app.tapisConfig.tenant)"
      ).path

      _ = stubAPI(on: app, [.ok(path, json)])

      let pem = try await TapisClient(client: app.client, config: app.tapisConfig)
        .getTenantPublicKey()

      // The real assertion: JWTKit accepts what comes back.
      #expect(throws: Never.self) {
        _ = try Insecure.RSA.PublicKey(pem: pem)
      }
    }
  }

  // MARK: - Admins

  @Test
  func `The root admin holds access with an empty table`() async throws {
    try await withInsightsApp { app in
      #expect(try await Admin.query(on: app.db).count() == 0)

      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: app.adminAuth,
        afterResponse: { res async throws in #expect(res.status == .ok) },
      )
    }
  }

  @Test
  func `A table admin gains access`() async throws {
    try await withInsightsApp { app in
      let token = try await signTapisToken(on: app, username: "newcomer")

      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: bearer(token),
        afterResponse: { res async throws in #expect(res.status == .forbidden) },
      )

      try await makeAdmin(on: app.db, username: "newcomer")

      // No restart and no new token: admin status is resolved per request during authentication.
      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: bearer(token),
        afterResponse: { res async throws in #expect(res.status == .ok) },
      )
    }
  }

  @Test
  func `Removing an admin revokes access on the next request`() async throws {
    try await withInsightsApp { app in
      let admin = try await makeAdmin(on: app.db, username: "temporary")
      let token = try await signTapisToken(on: app, username: "temporary")

      try await app.testing().test(
        .DELETE,
        "api/admins/\(try admin.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in #expect(res.status == .noContent) },
      )

      try await app.testing().test(
        .GET,
        "api/vaults",
        headers: bearer(token),
        afterResponse: { res async throws in #expect(res.status == .forbidden) },
      )
    }
  }

  @Test
  func `The root admin cannot be removed through the API`() async throws {
    try await withInsightsApp { app in
      // Written directly, since `create` refuses to duplicate the root admin. This is the
      // break-glass guarantee: no API call can strip the deployment owner of access.
      let row = try await makeAdmin(on: app.db, username: app.rootAdmin)

      try await app.testing().test(
        .DELETE,
        "api/admins/\(try row.requireID())",
        headers: app.adminAuth,
        afterResponse: { res async throws in #expect(res.status == .forbidden) },
      )
    }
  }

  @Test
  func `The listing includes the root admin`() async throws {
    try await withInsightsApp { app in
      try await makeAdmin(on: app.db, username: "someone")

      try await app.testing().test(
        .GET,
        "api/admins",
        headers: app.adminAuth,
        afterResponse: { res async throws in
          let listed = try res.content.decode([Admin.Public].self)
          #expect(listed.count == 2)
          #expect(listed.first?.username == app.rootAdmin)
          #expect(listed.first?.isRoot == true)
          #expect(listed.last?.username == "someone")
        },
      )
    }
  }

  @Test
  func `A non-admin cannot grant themselves access`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .POST,
        "api/admins",
        headers: app.userAuth,
        beforeRequest: { req in
          try req.content.encode(Admin.Create(username: "not-an-admin"))
        },
        afterResponse: { res async throws in
          #expect(res.status == .forbidden)
          #expect(try await Admin.query(on: app.db).count() == 0)
        },
      )
    }
  }

  @Test
  func `Granting the same username twice is a conflict`() async throws {
    try await withInsightsApp { app in
      try await makeAdmin(on: app.db, username: "twice")

      try await app.testing().test(
        .POST,
        "api/admins",
        headers: app.adminAuth,
        beforeRequest: { req in try req.content.encode(Admin.Create(username: "twice")) },
        afterResponse: { res async throws in
          #expect(res.status == .conflict)
          #expect(try await Admin.query(on: app.db).count() == 1)
        },
      )
    }
  }

  // MARK: - Frame ancestors

  @Test
  func `Framing is denied when no ancestors are configured`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(res.headers.first(name: .xFrameOptions) == "DENY")
          #expect(res.headers.first(name: .contentSecurityPolicy) == "frame-ancestors 'none'")
        },
      )
    }
  }

  @Test
  func `A configured ancestor is permitted and X-Frame-Options is dropped`() async throws {
    setenv("FRAME_ANCESTORS", "https://tapisui.example.org", 1)
    defer { unsetenv("FRAME_ANCESTORS") }

    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(
            res.headers.first(name: .contentSecurityPolicy)
              == "frame-ancestors 'self' https://tapisui.example.org")

          // Dropped deliberately: the header has no allowlist form, so leaving `DENY` in place
          // would contradict the policy and browsers preferring it would refuse the embed.
          #expect(res.headers.first(name: .xFrameOptions) == nil)
        },
      )
    }
  }

  @Test
  func `A malformed frame ancestor is discarded rather than widening the policy`() async throws {
    // A path-bearing origin is the realistic mistake. Passing it through would produce a policy
    // the browser rejects wholesale, which fails open on framing — the opposite of the intent.
    setenv("FRAME_ANCESTORS", "https://ok.example.org,https://bad.example.org/app,notaurl", 1)
    defer { unsetenv("FRAME_ANCESTORS") }

    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          #expect(
            res.headers.first(name: .contentSecurityPolicy)
              == "frame-ancestors 'self' https://ok.example.org")
        },
      )
    }
  }

  @Test
  func `The frame policy is stamped on error responses too`() async throws {
    setenv("FRAME_ANCESTORS", "https://tapisui.example.org", 1)
    defer { unsetenv("FRAME_ANCESTORS") }

    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/vaults",
        afterResponse: { res async throws in
          #expect(res.status == .unauthorized)
          #expect(
            res.headers.first(name: .contentSecurityPolicy)
              == "frame-ancestors 'self' https://tapisui.example.org")
        },
      )
    }
  }

  // MARK: - Request IDs

  @Test
  func `Every response carries a request ID`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        afterResponse: { res async throws in
          let id = res.headers.first(name: "X-Request-ID")
          #expect(id != nil)
          #expect(!(id ?? "").isEmpty)
        },
      )
    }
  }

  @Test
  func `A caller supplied request ID is echoed back`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        headers: ["X-Request-ID": "frontend-trace-42"],
        afterResponse: { res async throws in
          // Honoring the caller's value is what lets a frontend bug report name one request
          // across both sides of the call.
          #expect(res.headers.first(name: "X-Request-ID") == "frontend-trace-42")
        },
      )
    }
  }

  @Test
  func `A request ID carrying a newline is replaced rather than echoed`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        headers: ["X-Request-ID": "abc\ndef"],
        afterResponse: { res async throws in
          let id = res.headers.first(name: "X-Request-ID")
          // The value reaches log metadata verbatim, where an embedded newline can forge a log
          // line. Substituted, not stripped — see `RequestIDMiddleware.sanitize`.
          #expect(id != "abc\ndef")
          #expect(id?.contains("\n") == false)
        },
      )
    }
  }

  @Test
  func `An over-long request ID is replaced`() async throws {
    let oversized = String(repeating: "a", count: RequestIDMiddleware.maxLength + 1)

    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "api/resources",
        headers: ["X-Request-ID": oversized],
        afterResponse: { res async throws in
          #expect(res.headers.first(name: "X-Request-ID") != oversized)
        },
      )
    }
  }

  @Test
  func `Request IDs differ between requests when none is supplied`() async throws {
    try await withInsightsApp { app in
      var seen: [String] = []

      for _ in 0..<2 {
        try await app.testing().test(
          .GET,
          "api/resources",
          afterResponse: { res async throws in
            seen.append(res.headers.first(name: "X-Request-ID") ?? "")
          },
        )
      }

      #expect(seen.count == 2)
      #expect(seen[0] != seen[1])
    }
  }

  // MARK: - Health probes

  @Test
  func `Liveness reports ok`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "health",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          #expect(try res.content.decode(HealthController.Status.self).status == "ok")
        },
      )
    }
  }

  @Test
  func `Readiness reports ready when the dependencies answer`() async throws {
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "ready",
        afterResponse: { res async throws in
          #expect(res.status == .ok)
          #expect(try res.content.decode(HealthController.Status.self).status == "ready")
        },
      )
    }
  }

  @Test
  func `Health probes are not behind authentication`() async throws {
    // An orchestrator presents no credentials. A probe that 401s reads as a dead pod.
    try await withInsightsApp { app in
      try await app.testing().test(
        .GET,
        "health",
        afterResponse: { res async throws in
          #expect(res.status != .unauthorized)
        },
      )
    }
  }
}
