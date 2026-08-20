import Vapor

extension Application {
  private struct TapisConfigKey: StorageKey {
    typealias Value = TapisConfig
  }

  /// Tenant-scoped Tapis settings, loaded once at boot.
  ///
  /// Held separately from `app.secrets` because two unrelated things need it: the Vault client
  /// behind ``SecretProvider``, and ``TapisAuthenticator``, which compares a caller's
  /// `tapis/tenant_id` against ``TapisConfig/tenant``.
  var tapisConfig: TapisConfig {
    get {
      guard let config = storage[TapisConfigKey.self] else {
        fatalError("Tapis not configured — set app.tapisConfig in configure.swift")
      }
      return config
    }
    set { storage[TapisConfigKey.self] = newValue }
  }
}
