import Fluent
import Foundation
import Vapor

/// Manages the webhook tokens deployed ICICLE services use to report their own metrics.
///
/// The dashboard does the same things through `ServiceTokenController`; both are thin wrappers
/// over ``ServiceTokenIssuer``, so a token minted here behaves identically to one minted there.
/// This path stays because it works before the frontend exists — including `init-key`, which has
/// to run once before anything can be issued at all.
struct ServiceTokenCommand: AsyncCommandGroup {
  var commands: [String: any AnyAsyncCommand] {
    [
      "init-key": InitSigningKeyCommand(),
      "rotate-key": RotateSigningKeyCommand(),
      "issue": IssueServiceTokenCommand(),
      "revoke": RevokeServiceTokenCommand(),
      "list": ListServiceTokensCommand(),
    ]
  }

  var help: String {
    "Issue, list, and revoke webhook tokens for deployed services."
  }
}

/// Creates the initial keyset. Must run once before any token can be issued.
struct InitSigningKeyCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Flag(name: "force", help: "Discard the existing keyset. Invalidates every issued token.")
    var force: Bool
  }

  var help: String {
    "Create the webhook token signing keyset in Vault."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application
    let name = ServiceTokenSigningKey.secretName

    // Discarding the keyset invalidates every token at once. `rotate-key` is the non-destructive
    // path, so this refuses rather than quietly taking every deployed service offline.
    if !signature.force, (try? await application.secrets.readSecret(named: name)) != nil {
      context.console.warning("A keyset already exists at '\(name)'.")
      context.console.warning("Use `service-token rotate-key` to rotate without breaking tokens.")
      context.console.warning("Pass --force to discard it and invalidate every issued token.")
      return
    }

    try await application.secrets.writeSecret(
      named: name, secret: try ServiceTokenSigningKey.encode(ServiceTokenSigningKey.initial()))

    context.console.info("Keyset written to Vault secret '\(name)'.")
    context.console.info("Restart the API to load it.")
  }
}

/// Adds a new signing key and makes it active, keeping the previous ones for verification.
struct RotateSigningKeyCommand: AsyncCommand {
  struct Signature: CommandSignature {}

  var help: String {
    "Rotate the webhook signing key. Existing tokens keep working until they expire."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application
    let kid = try await application.rotateServiceTokenKey(using: application.secrets)

    context.console.info("Rotated. New tokens are signed with kid '\(kid)'.")
    context.console.info("Previously issued tokens keep verifying until they expire.")
    // Worth stating explicitly: this command mutates Vault, and a separately running API
    // process still holds the old keyset in memory until it reloads or restarts.
    context.console.warning("A running API picks this up on its next restart.")
  }
}

/// Mints a token bound to one resource.
struct IssueServiceTokenCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Option(name: "resource", short: "r", help: "UUID of the resource this token may write to.")
    var resource: String?

    @Option(name: "label", short: "l", help: "Deployment name, e.g. 'prod-inference'.")
    var label: String?

    @Option(name: "expires-in-days", help: "Days until expiry. Defaults to 90.")
    var expiresInDays: Int?
  }

  var help: String {
    "Issue a webhook token. The token is printed once and cannot be recovered."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application

    guard let raw = signature.resource, let resourceID = UUID(uuidString: raw) else {
      throw ConfigError.missing("--resource (a resource UUID)")
    }
    guard let label = signature.label, !label.isEmpty else {
      throw ConfigError.missing("--label")
    }

    let issuer = ServiceTokenIssuer(
      db: application.db,
      keys: application.serviceTokenKeys,
      activeKid: application.activeSigningKid,
    )
    let issued = try await issuer.mint(
      resourceID: resourceID,
      label: label,
      lifetimeInDays: signature.expiresInDays,
    )

    // Printed to the console, never logged: the logger ships to Slack and to wherever the
    // cluster collects stdout as structured records.
    context.console.warning("Token for '\(label)' — shown once, there is no recovery path:")
    context.console.print(issued.token)
    context.console.info("")
    context.console.info("Endpoint: /api/resources/\(resourceID)/metrics")
    context.console.info("Expires:  \(issued.record.expiresAt)")
    context.console.info("Any previous token for this resource has been revoked.")
  }
}

/// Withdraws a token by its `jti`.
struct RevokeServiceTokenCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Option(name: "jti", short: "j", help: "The token's jti, as shown by `service-token list`.")
    var jti: String?
  }

  var help: String {
    "Revoke a webhook token. Effective on its next request, with no restart."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application

    guard let raw = signature.jti, let jti = UUID(uuidString: raw) else {
      throw ConfigError.missing("--jti (a token jti)")
    }

    let issuer = ServiceTokenIssuer(
      db: application.db,
      keys: application.serviceTokenKeys,
      activeKid: application.activeSigningKid,
    )

    guard let record = try await issuer.revoke(jti: jti) else {
      context.console.warning("No token with jti '\(jti)'.")
      return
    }

    context.console.info("Revoked '\(record.label)'. Its next request is refused.")
  }
}

/// Lists tokens and their state. Values are never stored, so none can be shown.
struct ListServiceTokensCommand: AsyncCommand {
  struct Signature: CommandSignature {}

  var help: String {
    "List webhook tokens, newest first."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let application = context.application
    let issuer = ServiceTokenIssuer(
      db: application.db,
      keys: application.serviceTokenKeys,
      activeKid: application.activeSigningKid,
    )
    let records = try await issuer.list()

    guard !records.isEmpty else {
      context.console.info("No tokens issued.")
      return
    }

    for record in records {
      let state =
        if let revokedAt = record.revokedAt {
          "revoked \(revokedAt)"
        } else if record.expiresAt < Date() {
          "expired \(record.expiresAt)"
        } else {
          "live until \(record.expiresAt)"
        }

      context.console.print(
        "\(record.label)  resource=\(record.$resource.id)  jti=\(record.jti)  \(state)")
    }
  }
}
