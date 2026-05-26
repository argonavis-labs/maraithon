import Foundation
import Observation

/// Per-source toggle state for "Surface in Mac Spotlight". Persisted
/// to `UserDefaults` so a flip survives an app relaunch. Reads + writes
/// are cheap, so we go through `UserDefaults` directly rather than
/// caching in-memory state and worrying about coherency.
///
/// Default values are baked into `defaultEnabled(forSource:)` so a
/// fresh install lights up the safe sources (notes / voice memos /
/// reminders / calendar / files) and leaves the sensitive ones
/// (iMessage / browser history) off until the user explicitly opts
/// in. Privacy-by-default; the user can flip iMessage on from
/// Settings → Privacy if they want.
///
/// `@Observable` so the Settings pane can `@Bindable` it; the model
/// is `@MainActor` because the SwiftUI binding wants single-actor
/// access and our settings toggles only fire from the UI.
@Observable
@MainActor
public final class SpotlightTogglesStore {
    /// Source identifiers we recognise. Anything not in this list is
    /// treated as opt-out — defensive default so a future source has
    /// to consciously appear in this list before it shows up in
    /// Spotlight.
    public static let knownSources: [String] = [
        "notes",
        "voice_memos",
        "reminders",
        "calendar",
        "files",
        "imessage",
        "browser_history"
    ]

    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "spotlight.surface."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// Returns the current toggle state for `source`. Sources without
    /// a persisted value fall back to `defaultEnabled(forSource:)`.
    public func isEnabled(source: String) -> Bool {
        let key = self.key(source: source)
        if let stored = defaults.object(forKey: key) as? Bool {
            return stored
        }
        return Self.defaultEnabled(forSource: source)
    }

    /// Toggle the surfacing of a single source.
    public func setEnabled(_ enabled: Bool, source: String) {
        defaults.set(enabled, forKey: key(source: source))
    }

    /// Drop every persisted toggle so the next read returns the
    /// hard-coded defaults. Used by the tests; not surfaced to the UI.
    public func reset() {
        for source in Self.knownSources {
            defaults.removeObject(forKey: key(source: source))
        }
    }

    /// Defaults follow the privacy table in the brief. Sources whose
    /// content is sensitive by nature start OFF; everything else
    /// starts ON. New sources fall back to OFF until they're added to
    /// `knownSources` and explicitly enabled here — fail-closed beats
    /// fail-open for a privacy toggle.
    public static func defaultEnabled(forSource source: String) -> Bool {
        switch source {
        case "notes", "voice_memos", "reminders", "calendar", "files":
            return true
        case "imessage", "browser_history":
            return false
        default:
            return false
        }
    }

    private func key(source: String) -> String {
        keyPrefix + source
    }
}
