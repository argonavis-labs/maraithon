import Foundation

/// Persists the Notes sync cursor across launches.
///
/// Two-pointer model identical to `IMessageCursor`:
///   * `newestSeen` — highest `Z_PK` ever pushed. New notes are anything
///     with a higher rowid.
///   * `backfillFrom` — lowest rowid the descending backfill walk has
///     reached. History gets walked newest-first.
///
/// Stored under:
///   * `com.maraithon.companion.notes.cursor` (legacy key → newestSeen)
///   * `com.maraithon.companion.notes.backfill_from`
struct NotesCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.notes.cursor"
    static let backfillDefaultsKey = "com.maraithon.companion.notes.backfill_from"

    static let backfillSentinel: Int64 = .max

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var newestSeen: Int64 {
        Int64(defaults.integer(forKey: Self.defaultsKey))
    }

    var backfillFrom: Int64 {
        let raw = defaults.object(forKey: Self.backfillDefaultsKey) as? Int
        return raw.map(Int64.init) ?? Self.backfillSentinel
    }

    func advanceNewest(to rowID: Int64) {
        guard rowID > newestSeen else { return }
        defaults.set(Int(rowID), forKey: Self.defaultsKey)
        defaults.synchronize()
    }

    func advanceBackfill(to rowID: Int64) {
        guard rowID < backfillFrom else { return }
        defaults.set(Int(rowID), forKey: Self.backfillDefaultsKey)
        defaults.synchronize()
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.backfillDefaultsKey)
        defaults.synchronize()
    }

    // Legacy aliases for callers / tests still using the old names.
    var lastSyncedRowID: Int64 { newestSeen }
    func advance(to rowID: Int64) { advanceNewest(to: rowID) }
}
