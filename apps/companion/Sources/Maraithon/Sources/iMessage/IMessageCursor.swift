import Foundation

/// Persists the iMessage sync cursor across launches.
///
/// The cursor is a two-pointer model: each cycle pulls the **newest**
/// unseen messages first (rowid > `newestSeen`) and falls through to a
/// **backfill** walk (rowid < `backfillFrom`) when there's nothing new.
/// That way a freshly-paired device sees today's messages on the first
/// cycle, then walks history backward in time.
///
/// Stored in `UserDefaults`:
///   * `com.maraithon.companion.imessage.cursor` — `newestSeen` (legacy
///     key, kept stable for migration so existing installs resume).
///   * `com.maraithon.companion.imessage.backfill_from` — `backfillFrom`.
///
/// Both pointers are monotonic in their respective directions
/// (`newestSeen` only increases; `backfillFrom` only decreases). The
/// `advance*` methods refuse to move backwards.
struct IMessageCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.imessage.cursor"
    static let backfillDefaultsKey = "com.maraithon.companion.imessage.backfill_from"

    /// Sentinel for "no backfill walk has started yet, anything is fair
    /// game." `Int64.max` so SQL `rowid < ?` matches every row.
    static let backfillSentinel: Int64 = .max

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Highest rowid we've ever pushed. Anything strictly greater is a
    /// brand-new message to ship on the next cycle. Defaults to `0`.
    var newestSeen: Int64 {
        Int64(defaults.integer(forKey: Self.defaultsKey))
    }

    /// Lowest rowid the descending backfill walk has reached. Anything
    /// strictly less is unsynced history. Defaults to
    /// `backfillSentinel` so the first backfill query matches every
    /// row.
    var backfillFrom: Int64 {
        let raw = defaults.object(forKey: Self.backfillDefaultsKey) as? Int
        return raw.map(Int64.init) ?? Self.backfillSentinel
    }

    /// Advance `newestSeen` upward. No-op if `rowID` is not strictly
    /// greater than the current value.
    func advanceNewest(to rowID: Int64) {
        guard rowID > newestSeen else { return }
        defaults.set(Int(rowID), forKey: Self.defaultsKey)
    }

    /// Move `backfillFrom` downward. No-op if `rowID` is not strictly
    /// less than the current value.
    func advanceBackfill(to rowID: Int64) {
        guard rowID < backfillFrom else { return }
        defaults.set(Int(rowID), forKey: Self.backfillDefaultsKey)
    }

    /// Wipe both pointers. Used by `IMessageSource.clearLocalState`.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.backfillDefaultsKey)
    }

    // MARK: - Legacy

    /// Legacy accessor — equivalent to `newestSeen`. Retained so call
    /// sites that haven't migrated yet keep compiling. Prefer
    /// `newestSeen` / `backfillFrom` in new code.
    var lastSyncedRowID: Int64 { newestSeen }

    /// Legacy advance — equivalent to `advanceNewest`. Retained for
    /// tests and back-compat.
    func advance(to rowID: Int64) { advanceNewest(to: rowID) }
}
