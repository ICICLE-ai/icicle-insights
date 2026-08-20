import Foundation
import JWT
import NIOConcurrencyHelpers
import Vapor

extension Application {
  private struct ServiceTokenKeysKey: StorageKey {
    typealias Value = JWTKeyCollection
  }

  private struct ActiveKidKey: StorageKey {
    typealias Value = NIOLockedValueBox<String>
  }

  /// Key collection for webhook tokens this server mints and verifies.
  ///
  /// Deliberately **not** `app.jwt.keys`, which holds the Tapis tenant's keys. Sharing one
  /// collection across two trust domains is a correctness bug waiting to happen: JWTKit falls
  /// back to whichever signer is registered as default when a token's `kid` is unknown, and
  /// Tapis tokens carry a `kid` this server never registers. A legitimate admin would then be
  /// verified against the HMAC key and rejected.
  ///
  /// Never replaced after boot. Rotation *adds* to it — `JWTKeyCollection` is an actor, so
  /// registering a key at runtime is safe, whereas swapping the stored value out from under
  /// in-flight requests would not be.
  var serviceTokenKeys: JWTKeyCollection {
    get {
      guard let keys = storage[ServiceTokenKeysKey.self] else {
        fatalError("Signing keys not configured — set app.serviceTokenKeys in configure.swift")
      }
      return keys
    }
    set { storage[ServiceTokenKeysKey.self] = newValue }
  }

  /// The `kid` new tokens are signed with. Older registered keys stay valid for verification.
  var activeSigningKid: String {
    get {
      guard let box = storage[ActiveKidKey.self] else {
        fatalError("Signing keys not configured — set app.serviceTokenKeys in configure.swift")
      }
      return box.withLockedValue { $0 }
    }
    set {
      if let box = storage[ActiveKidKey.self] {
        box.withLockedValue { $0 = newValue }
      } else {
        storage[ActiveKidKey.self] = .init(newValue)
      }
    }
  }

  /// Loads the keyset from Vault and registers every key under its `kid`.
  ///
  /// Registering the retired keys too is what makes rotation survivable: tokens signed before a
  /// rotation keep verifying until they expire, so rotating is not a flag day for every deployed
  /// service at once.
  ///
  /// - Returns: How many keys were registered, or nil when no keyset exists yet. A count of one
  ///   after a rotation was expected to have happened means the retired keys were dropped and any
  ///   token still signed with them will be refused.
  /// - Throws: Any failure other than the secret being absent. A refused read — a stale
  ///   `TAPIS_TOKEN`, most likely — is a real misconfiguration that would break every collection
  ///   job, so it must not be mistaken for a deployment that simply has not been bootstrapped.
  @discardableResult
  func loadServiceTokenKeys(from provider: any SecretProvider) async throws -> Int? {
    let secret: Secret

    do {
      secret = try await provider.readSecret(named: ServiceTokenSigningKey.secretName)
    } catch let error as TapisClientError where error.isNotFound {
      // The first boot of any new deployment lands here. Throwing would be a catch-22: every
      // command routes through `configure`, so a hard failure takes down the very command that
      // creates this secret — `service-token init-key` could never run.
      //
      // Installing an empty collection instead leaves webhook authentication recognizing nobody,
      // which is exactly correct while no keyset exists, and leaves everything else working.
      installEmptyServiceTokenKeys()
      return nil
    }

    let keyset = try ServiceTokenSigningKey.decode(secret)
    let keys = JWTKeyCollection()

    for key in keyset.keys {
      await keys.add(
        hmac: .init(from: key.secret), digestAlgorithm: .sha256, kid: .init(string: key.kid))
    }

    serviceTokenKeys = keys
    activeSigningKid = keyset.active

    return keyset.keys.count
  }

  /// Installs a keyset that verifies nothing and signs nothing.
  ///
  /// Both accessors `fatalError` when unset, so "no keyset" has to be represented by real empty
  /// values rather than by absence. An empty `activeSigningKid` is the signal ``ServiceTokenIssuer``
  /// checks before attempting to mint.
  func installEmptyServiceTokenKeys() {
    serviceTokenKeys = JWTKeyCollection()
    activeSigningKid = ""
  }

  /// Registers a newly generated key and makes it active, without a restart.
  ///
  /// Adding to the live collection rather than rebuilding it is what keeps previously issued
  /// tokens working through the rotation.
  func rotateServiceTokenKey(using provider: any SecretProvider) async throws -> String {
    let existing = try ServiceTokenSigningKey.decode(
      try await provider.readSecret(named: ServiceTokenSigningKey.secretName))

    let fresh = ServiceTokenSigningKey.Key(
      kid: UUID().uuidString, secret: ServiceTokenSigningKey.generateSecret())

    // Keys older than the longest possible token lifetime can verify nothing, so drop them
    // rather than accumulating signing material forever.
    let retained = ([fresh] + existing.keys).prefix(ServiceTokenSigningKey.maxRetainedKeys)

    try await provider.writeSecret(
      named: ServiceTokenSigningKey.secretName,
      secret: try ServiceTokenSigningKey.encode(
        .init(active: fresh.kid, keys: Array(retained))),
    )

    await serviceTokenKeys.add(
      hmac: .init(from: fresh.secret), digestAlgorithm: .sha256, kid: .init(string: fresh.kid))
    activeSigningKid = fresh.kid

    return fresh.kid
  }
}

/// The signing material behind every webhook token, held as a keyset so it can be rotated
/// without invalidating tokens already in the field.
///
/// ```json
/// { "active": "k2", "keys": [ {"kid": "k2", "secret": "…"}, {"kid": "k1", "secret": "…"} ] }
/// ```
enum ServiceTokenSigningKey {
  struct Key: Codable, Sendable {
    let kid: String
    let secret: String
  }

  struct Keyset: Codable, Sendable {
    /// The `kid` new tokens are signed with.
    let active: String
    /// Newest first. Retired keys are kept only long enough to verify tokens signed with them.
    let keys: [Key]
  }

  /// One more than a token lifetime's worth of rotations, so a retired key always outlives the
  /// tokens it signed.
  static let maxRetainedKeys = 3

  /// Vault secret holding the keyset.
  static var secretName: String {
    Environment.get("TOKEN_SIGNING_SECRET") ?? "insights-token-signing-key"
  }

  /// Generates one key's material — 32 bytes from the platform CSPRNG, base64.
  static func generateSecret() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
  }

  /// A keyset containing a single fresh key, for `init-key`.
  static func initial() -> Keyset {
    let key = Key(kid: UUID().uuidString, secret: generateSecret())
    return Keyset(active: key.kid, keys: [key])
  }

  static func decode(_ secret: Secret) throws -> Keyset {
    do {
      return try JSONDecoder().decode(
        Keyset.self, from: Data(secret.getSecretValue().utf8))
    } catch {
      // The value is deliberately excluded from the error: it is signing material.
      throw ConfigError.unsupported(name: "TOKEN_SIGNING_SECRET", value: "unreadable JSON")
    }
  }

  static func encode(_ keyset: Keyset) throws -> String {
    String(decoding: try JSONEncoder().encode(keyset), as: UTF8.self)
  }
}
