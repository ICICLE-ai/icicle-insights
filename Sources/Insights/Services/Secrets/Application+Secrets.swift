import Vapor

extension Application {
  private struct SecretProviderKey: StorageKey {
    typealias Value = any SecretProvider
  }

  /// Application-scoped credential backend shared by jobs and Vault controllers.
  ///
  /// Configure this once in `configure.swift`. Consumers deliberately see only
  /// ``SecretProvider`` so replacing Tapis does not require changes throughout the app.
  var secrets: any SecretProvider {
    get {
      guard let provider = storage[SecretProviderKey.self] else {
        fatalError("SecretProvider not configured — set app.secrets in configure.swift")
      }
      return provider
    }
    set { storage[SecretProviderKey.self] = newValue }
  }
}
