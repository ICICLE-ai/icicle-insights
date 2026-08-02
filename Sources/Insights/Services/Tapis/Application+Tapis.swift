import Vapor

extension Application {
    private struct TapisClientKey: StorageKey {
        typealias Value = TapisClient
    }

    /// The shared `TapisClient`. Set once in `configure.swift`; reused by every job/controller.
    var tapis: TapisClient {
        get {
            guard let existing = storage[TapisClientKey.self] else {
                fatalError("TapisClient not configured — set app.tapis in configure.swift")
            }
            return existing
        }
        set { storage[TapisClientKey.self] = newValue }
    }
}
