import Foundation

/// The set of sources that participate in the opt-in client-side
/// encryption toggle. Browser history is intentionally excluded — it
/// drives ranking signals server-side and is the lowest-sensitivity
/// surface (every host is plaintext on the row already for the
/// privacy deny-list), so we don't trade that for a toggle.
enum EncryptableSource: String, CaseIterable, Sendable, Identifiable, Hashable {
    case notes
    case voiceMemos = "voice_memos"
    case messages = "imessage"
    case calendar
    case reminders
    case files

    var id: String { rawValue }

    /// Human-readable label for the Settings checkbox.
    var displayName: String {
        switch self {
        case .notes: return "Notes"
        case .voiceMemos: return "Voice Memos"
        case .messages: return "iMessage"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .files: return "Files"
        }
    }
}

/// Lightweight typed accessor for the per-source encryption toggles.
/// Stored in `UserDefaults` under one boolean key per source so the
/// Settings view can `@AppStorage`-bind directly. The constants live
/// here so ingest helpers + the UI agree on the same keys.
///
/// `@unchecked Sendable` because `UserDefaults` is documented
/// thread-safe — same posture as `UserDefaultsKeychain`. Swift 6
/// strict concurrency doesn't know that yet.
struct EncryptionSettings: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether end-to-end encryption is currently enabled for a given
    /// source. Default `false` — the toggle is opt-in.
    func isEnabled(for source: EncryptableSource) -> Bool {
        defaults.bool(forKey: Self.defaultsKey(for: source))
    }

    /// Persist a new value for the given source.
    func set(_ value: Bool, for source: EncryptableSource) {
        defaults.set(value, forKey: Self.defaultsKey(for: source))
    }

    /// Convenience: returns true if encryption is enabled for *any*
    /// source. Used by the SyncEngine to decide whether to make sure
    /// a device key has been published before the next batch goes out.
    var isAnyEnabled: Bool {
        EncryptableSource.allCases.contains(where: { isEnabled(for: $0) })
    }

    /// UserDefaults key for a given source. Public so tests can
    /// fixture-set the value without going through the type.
    static func defaultsKey(for source: EncryptableSource) -> String {
        "com.maraithon.companion.encryption.\(source.rawValue).enabled"
    }
}
