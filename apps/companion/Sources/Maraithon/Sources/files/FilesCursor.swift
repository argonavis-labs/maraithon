import Foundation

/// Persists per-path modification timestamps so we know which files have
/// been pushed since the last scan. Stored in `UserDefaults` under
/// `com.maraithon.companion.files.cursor` as a `[path: modified_at_iso8601]`
/// dictionary.
///
/// Unlike iMessage / Notes / Voice Memos which key off a monotonic
/// SQLite rowid, the Files source has no central database — it walks a
/// filesystem. We track each absolute path's last-seen `modified_at`
/// so a follow-up scan can quickly skip unchanged files and only
/// re-emit ones whose mtime advanced (or that didn't exist before).
struct FilesCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.files.cursor"

    private let defaults: UserDefaults
    private let isoFormatter: ISO8601DateFormatter

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    /// Read the persisted `[path: modified_at]` map. Empty on first run.
    func snapshot() -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]
        else { return [:] }
        var out: [String: Date] = [:]
        out.reserveCapacity(raw.count)
        for (path, iso) in raw {
            if let date = isoFormatter.date(from: iso) {
                out[path] = date
            }
        }
        return out
    }

    /// Look up the last-seen mtime for one path, if any.
    func lastModified(for path: String) -> Date? {
        snapshot()[path]
    }

    /// Persist a fresh snapshot. Replaces the entire dictionary so paths
    /// that have been deleted from disk eventually fall out of the cursor.
    func write(_ snapshot: [String: Date]) {
        var raw: [String: String] = [:]
        raw.reserveCapacity(snapshot.count)
        for (path, date) in snapshot {
            raw[path] = isoFormatter.string(from: date)
        }
        defaults.set(raw, forKey: Self.defaultsKey)
    }

    /// Convenience: merge one (path, modified_at) into the existing map.
    /// Used when we want to record progress after each successful push
    /// without rebuilding the whole snapshot.
    func record(path: String, modifiedAt: Date) {
        var current = snapshot()
        current[path] = modifiedAt
        write(current)
    }

    /// Wipe the persisted cursor. Used by `FilesSource.clearLocalState`.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
