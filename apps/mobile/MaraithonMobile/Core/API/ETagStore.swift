import Foundation
import Synchronization

/// Thread-safe store of ETag values keyed by list endpoint, persisted in
/// UserDefaults so conditional GETs keep working across app relaunches.
///
/// A `Mutex` guards the in-memory dictionary, so the store is Sendable-correct
/// under strict concurrency without an actor hop on the hot request path.
final class ETagStore: Sendable {
    static let shared = ETagStore()

    private static let defaultsKey = "MobileAPIClient.etags"

    // UserDefaults is documented thread-safe but not annotated Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let etags: Mutex<[String: String]>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        etags = Mutex(defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:])
    }

    func etag(for key: String) -> String? {
        etags.withLock { $0[key] }
    }

    /// Stores the ETag for an endpoint key; passing `nil` removes any stored
    /// value (used when a server stops sending ETags so a stale validator is
    /// not replayed forever).
    func set(_ value: String?, for key: String) {
        etags.withLock { stored in
            stored[key] = value
            defaults.set(stored, forKey: Self.defaultsKey)
        }
    }

    func clearAll() {
        etags.withLock { stored in
            stored = [:]
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}
