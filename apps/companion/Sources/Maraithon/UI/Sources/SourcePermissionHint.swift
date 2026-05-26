import Foundation

/// User-facing copy + deep link for a known `.needsAttention` reason
/// string a source publishes. Adding a new reason here is enough to give
/// it a focused unblock UI — the scaffold reads from this mapping.
///
/// Invariant: every reason string emitted by `SourceProtocol`
/// implementations should resolve to a concrete hint here. Unknown
/// reasons fall back to a generic "This source needs attention" view
/// that surfaces the raw reason but offers no settings deep link.
struct SourcePermissionHint: Equatable {
    let title: String
    /// Plain-English body explaining what's missing and where to grant
    /// it. Single paragraph; no Markdown.
    let body: String
    /// `x-apple.systempreferences:` URL that opens the right Privacy
    /// pane. `nil` when no deep link applies (rare).
    let settingsURL: URL?
    /// Optional follow-up note about toggling / relaunching. macOS
    /// sometimes requires the app to relaunch after a TCC grant flip;
    /// this line tells the user what to do if "Check again" doesn't
    /// flip the state.
    let relaunchNote: String?

    static func forReason(_ reason: String) -> SourcePermissionHint {
        switch reason {
        case "calendar_not_authorized":
            return SourcePermissionHint(
                title: "Calendar access needed",
                body: "Maraithon needs permission to read your calendar events. Open System Settings → Privacy & Security → Calendars, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
                relaunchNote: "If Maraithon is already listed, toggle it off and back on. macOS may ask you to relaunch the app — quit and reopen, then tap Check again."
            )
        case "reminders_not_authorized":
            return SourcePermissionHint(
                title: "Reminders access needed",
                body: "Maraithon needs permission to read your reminders. Open System Settings → Privacy & Security → Reminders, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"),
                relaunchNote: "If Maraithon is already listed, toggle it off and back on. macOS may ask you to relaunch the app — quit and reopen, then tap Check again."
            )
        case "voice_memos_speech_disabled":
            return SourcePermissionHint(
                title: "Speech Recognition is off",
                body: "Voice Memos sync, but transcripts need Siri & Dictation enabled. Open System Settings → Privacy & Security → Speech Recognition and turn it on for Maraithon, then make sure Dictation is enabled in Keyboard settings.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"),
                relaunchNote: "After enabling, tap Check again. New voice memos will get transcripts on the next sync; existing memos pick up transcripts when their audio re-flows."
            )
        default:
            return SourcePermissionHint(
                title: "This source needs attention",
                body: reason,
                settingsURL: nil,
                relaunchNote: nil
            )
        }
    }
}
