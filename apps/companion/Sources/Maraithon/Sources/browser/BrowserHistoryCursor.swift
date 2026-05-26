import Foundation

/// Per-browser cursor for the browser history source. Each browser
/// keeps its own monotonic integer cursor — Chromium uses `urls.id`
/// and Safari uses `history_items.id`. Storing them in one
/// `UserDefaults` key as a `[String: Int64]` map (keyed by browser
/// rawValue) keeps the registration story simple: install or remove a
/// browser and the cursor lives or dies with it.
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

    /// The last successfully-pushed cursor for the given browser, or 0
    /// on first run.
    func lastSyncedID(for browser: Browser) -> Int64 {
        let map = readMap()
        return map[browser.rawValue] ?? 0
    }

    /// Advance the cursor for the given browser. Refuses to move
    /// backwards so out-of-order pushes can't undo progress.
    func advance(_ browser: Browser, to id: Int64) {
        var map = readMap()
        let current = map[browser.rawValue] ?? 0
        guard id > current else { return }
        map[browser.rawValue] = id
        writeMap(map)
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
