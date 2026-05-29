import Foundation

/// User-facing copy + deep link for a known `.needsAttention` reason
/// string a source publishes. Adding a new reason here is enough to give
/// it a focused unblock UI — the scaffold reads from this mapping.
///
/// Invariant: every permission reason emitted by `SourceProtocol`
/// implementations should resolve to a concrete hint here. Unknown
/// reasons fall back to a generic "This source needs attention" view
/// that shows sanitized recovery copy and offers no settings deep link.
struct SourcePermissionHint: Equatable {
    let title: String
    /// Plain-English body explaining what's missing and where to grant
    /// it. Single paragraph; no Markdown.
    let body: String
    /// `x-apple.systempreferences:` URL that opens the right Privacy
    /// pane. `nil` when no deep link applies (rare).
    let settingsURL: URL?
    /// Optional follow-up note for the recovery path after the user
    /// changes a macOS permission.
    let followUpNote: String?
    /// True for Full Disk Access reasons where debug builds must be
    /// launched from a stable app bundle to keep the macOS TCC grant.
    let requiresStableFullDiskAccessApp: Bool

    init(
        title: String,
        body: String,
        settingsURL: URL?,
        followUpNote: String?,
        requiresStableFullDiskAccessApp: Bool = false
    ) {
        self.title = title
        self.body = body
        self.settingsURL = settingsURL
        self.followUpNote = followUpNote
        self.requiresStableFullDiskAccessApp = requiresStableFullDiskAccessApp
    }

    static func forReason(_ reason: String) -> SourcePermissionHint {
        switch reason {
        case "calendar_not_authorized":
            return SourcePermissionHint(
                title: "Calendar access needed",
                body: "Maraithon needs permission to read your calendar events. Open System Settings → Privacy & Security → Calendars, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
                followUpNote: "If Maraithon is already listed, toggle it off and back on. macOS may ask you to relaunch the app — quit and reopen, then tap Check again."
            )
        case "reminders_not_authorized":
            return SourcePermissionHint(
                title: "Reminders access needed",
                body: "Maraithon needs permission to read your reminders. Open System Settings → Privacy & Security → Reminders, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"),
                followUpNote: "If Maraithon is already listed, toggle it off and back on. macOS may ask you to relaunch the app — quit and reopen, then tap Check again."
            )
        case "imessage_full_disk_access_required":
            return SourcePermissionHint(
                title: "iMessage access needed",
                body: "Maraithon needs Full Disk Access to read your local iMessage history on this Mac. Open System Settings → Privacy & Security → Full Disk Access, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                followUpNote: FullDiskAccessCopy.unblockFollowUp,
                requiresStableFullDiskAccessApp: true
            )
        case "notes_full_disk_access_required":
            return SourcePermissionHint(
                title: "Notes access needed",
                body: "Maraithon needs Full Disk Access to read your local Notes on this Mac. Open System Settings → Privacy & Security → Full Disk Access, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                followUpNote: FullDiskAccessCopy.unblockFollowUp,
                requiresStableFullDiskAccessApp: true
            )
        case "voice_memos_speech_disabled":
            return SourcePermissionHint(
                title: "Siri or Dictation is off",
                body: "Voice Memos still sync, but macOS is refusing local transcription because Siri or Dictation is disabled. Open System Settings → Apple Intelligence & Siri and turn Siri on, or open Keyboard → Dictation and turn Dictation on.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
                followUpNote: "After enabling Siri or Dictation, tap Check again. New voice memos will get transcripts on the next sync; existing memos pick up transcripts when their audio re-flows."
            )
        case "voice_memos_speech_not_authorized":
            return SourcePermissionHint(
                title: "Speech Recognition access needed",
                body: "Voice Memos sync, but transcripts need Speech Recognition permission. Open System Settings → Privacy & Security → Speech Recognition, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"),
                followUpNote: "After enabling, tap Check again. New voice memos will get transcripts on the next sync."
            )
        case "voice_memos_full_disk_access_required":
            return SourcePermissionHint(
                title: "Voice Memos access needed",
                body: "Maraithon needs Full Disk Access to read your local Voice Memos and audio files on this Mac. Open System Settings → Privacy & Security → Full Disk Access, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                followUpNote: FullDiskAccessCopy.unblockFollowUp,
                requiresStableFullDiskAccessApp: true
            )
        default:
            return SourcePermissionHint(
                title: "This source needs attention",
                body: SourceIssueCopy.status(reason),
                settingsURL: nil,
                followUpNote: nil
            )
        }
    }
}
