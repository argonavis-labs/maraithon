import Foundation

/// Persists the (guid → modified_at) map of every calendar occurrence
/// we've pushed, so a restart only re-uploads occurrences whose
/// EventKit `lastModifiedDate` has advanced.
///
/// Calendar events differ from notes/voice-memos: there's no monotonic
/// `Z_PK` we can resume from. EventKit exposes a per-occurrence
/// derived `guid` (see `CalendarEventReader.derivedGuid`) plus a
/// `lastModifiedDate` on the master event. The cursor stores the last
/// modification timestamp we've shipped for each derived guid; the
/// source re-pushes any occurrence whose current `lastModifiedDate` is
/// greater.
///
/// Stored in `UserDefaults` under
/// `com.maraithon.companion.calendar.cursor` as a `[String: Double]`
/// (guid → seconds since the reference date). Tests can substitute
/// their own suite via the initializer.
struct CalendarCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.calendar.cursor"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read the persisted (guid → timestamp) snapshot. Returns an empty
    /// map on first run or when the value is corrupt — we re-sync
    /// everything in that case, and the server's idempotent upsert
    /// keeps the operation safe.
    var snapshot: [String: Date] {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) else {
            return [:]
        }
        var out: [String: Date] = [:]
        out.reserveCapacity(raw.count)
        for (guid, value) in raw {
            if let seconds = value as? Double {
                out[guid] = Date(timeIntervalSinceReferenceDate: seconds)
            } else if let intSeconds = value as? Int {
                out[guid] = Date(timeIntervalSinceReferenceDate: Double(intSeconds))
            }
        }
        return out
    }

    /// `true` when this guid hasn't been seen, or when the supplied
    /// modification timestamp is strictly newer than the persisted
    /// one. `nil` modification dates always re-push (we treat them
    /// like a fresh sighting because we can't compare).
    func shouldPush(guid: String, modifiedAt: Date?) -> Bool {
        guard let modifiedAt else { return true }
        guard let last = snapshot[guid] else { return true }
        return modifiedAt > last
    }

    /// Record the modification timestamps of a batch we just pushed
    /// successfully. Merges into the existing snapshot — entries for
    /// guids not in `entries` are preserved.
    func advance(_ entries: [(guid: String, modifiedAt: Date)]) {
        guard !entries.isEmpty else { return }
        var raw = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        for entry in entries {
            raw[entry.guid] = entry.modifiedAt.timeIntervalSinceReferenceDate
        }
        defaults.set(raw, forKey: Self.defaultsKey)
    }

    /// Number of guids tracked. Cheap window into cursor size for
    /// logging without exposing the full dictionary.
    var trackedCount: Int {
        defaults.dictionary(forKey: Self.defaultsKey)?.count ?? 0
    }

    /// Wipe the persisted cursor. Used by
    /// `CalendarEventsSource.clearLocalState`.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
