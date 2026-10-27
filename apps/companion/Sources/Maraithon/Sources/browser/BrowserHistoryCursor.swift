import Foundation

/// Per-database cursor for the browser history source. Each history
/// database keeps its own monotonic integer cursor over the browser's
/// append-only per-visit id space — Chromium's `visits.id`, Safari's
/// `history_visits.id` — keyed by the reader's `cursorKey`
/// (`chrome:Default#visits`, `safari#visits`, …). Storing them in one
/// `UserDefaults` key as a `[String: Int64]` map keeps the registration
/// story simple: install or remove a browser and the cursor lives or
/// dies with it. Bare browser-name keys from the pre-visit-cursor era
/// (which held `urls.id` values) may linger in the map; nothing reads
/// them.
///
/// Stored in `UserDefaults` under
/// `com.maraithon.companion.browser_history.cursor`. Tests substitute
/// their own suite via the initializer.
struct BrowserHistoryCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.browser_history.cursor"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last successfully-pushed cursor for the given key, or 0 on
    /// first run.
    func lastSyncedID(forKey key: String) -> Int64 {
        let map = readMap()
        return map[key] ?? 0
    }

    /// Advance the cursor for the given key. Refuses to move backwards
    /// so out-of-order pushes can't undo progress.
    func advance(key: String, to id: Int64) {
        var map = readMap()
        let current = map[key] ?? 0
        guard id > current else { return }
        map[key] = id
        writeMap(map)
    }

    /// Browser-level convenience over the single-database key — used by
    /// tests and any caller that predates multi-profile readers.
    func lastSyncedID(for browser: Browser) -> Int64 {
        lastSyncedID(forKey: browser.rawValue)
    }

    /// Browser-level convenience twin of `advance(key:to:)`.
    func advance(_ browser: Browser, to id: Int64) {
        advance(key: browser.rawValue, to: id)
    }

    /// Wipe every browser's cursor. Used by
    /// `BrowserHistorySource.clearLocalState`.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func readMap() -> [String: Int64] {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) else {
            return [:]
        }
        var out: [String: Int64] = [:]
        for (k, v) in raw {
            if let n = v as? Int64 {
                out[k] = n
            } else if let n = v as? Int {
                out[k] = Int64(n)
            } else if let n = v as? NSNumber {
                out[k] = n.int64Value
            }
        }
        return out
    }

    private func writeMap(_ map: [String: Int64]) {
        // Store as `Int` so UserDefaults' plist round-trip is happy on
        // 32/64-bit boundaries; we widen back to `Int64` on read.
        let plist: [String: Int] = map.mapValues { Int($0) }
        defaults.set(plist, forKey: Self.defaultsKey)
    }
}
