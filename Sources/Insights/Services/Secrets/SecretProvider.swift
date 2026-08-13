/// A backend capable of managing named platform credentials for collection jobs.
///
/// Sync jobs depend on this provider-neutral contract rather than a particular secret manager.
/// Implementations may use Tapis Vault, HashiCorp Vault, a cloud secret manager, Kubernetes, or
/// another system without changing job code.
protocol SecretProvider: Sendable {
  /// Resolves a named credential for an authenticated outbound platform request.
  ///
  /// - Parameter name: Stable external key stored in the account's local Vault metadata.
  /// - Returns: A redacting wrapper around the resolved secret value.
  /// - Throws: A provider-specific lookup, authentication, transport, or decoding error.
  func readSecret(named name: String) async throws -> Secret

  /// Creates or replaces a named credential.
  ///
  /// - Parameters:
  ///   - name: Stable external key stored in local metadata.
  ///   - secret: New plaintext value; implementations must keep it out of diagnostics.
  /// - Throws: A provider-specific write or authentication error.
  func writeSecret(named name: String, secret: String) async throws

  /// Permanently removes a named credential from the backing service.
  ///
  /// - Parameter name: Stable external key stored in local metadata.
  /// - Throws: A provider-specific deletion or authentication error.
  func destroySecret(named name: String) async throws
}
