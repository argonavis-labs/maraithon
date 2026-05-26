import Foundation

/// Persists the Voice Memos sync cursor across launches. Two-pointer
/// model identical to `IMessageCursor` / `NotesCursor` — newer-first,
/// then descending backfill.
struct VoiceMemosCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.voice_memos.cursor"
    static let backfillDefaultsKey = "com.maraithon.companion.voice_memos.backfill_from"

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
    }

    func advanceBackfill(to rowID: Int64) {
        guard rowID < backfillFrom else { return }
        defaults.set(Int(rowID), forKey: Self.backfillDefaultsKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.backfillDefaultsKey)
    }

    // Legacy aliases.
    var lastSyncedRowID: Int64 { newestSeen }
    func advance(to rowID: Int64) { advanceNewest(to: rowID) }
}
