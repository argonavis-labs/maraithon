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
    /// User-facing label for the settings deep link. Keep this specific
    /// so a Calendar block does not look like another Full Disk Access
    /// prompt.
    let settingsButtonTitle: String
    /// Optional follow-up note for the recovery path after the user
    /// changes a macOS permission.
    let followUpNote: String?
    /// True for Full Disk Access reasons where debug builds must be
    /// launched from one persistent app bundle to keep the macOS TCC grant.
    let requiresStableFullDiskAccessApp: Bool

    init(
        title: String,
        body: String,
        settingsURL: URL?,
        settingsButtonTitle: String = "Open System Settings",
        followUpNote: String?,
        requiresStableFullDiskAccessApp: Bool = false
    ) {
        self.title = title
        self.body = body
        self.settingsURL = settingsURL
        self.settingsButtonTitle = settingsButtonTitle
        self.followUpNote = followUpNote
        self.requiresStableFullDiskAccessApp = requiresStableFullDiskAccessApp
    }

    static func forReason(_ reason: String) -> SourcePermissionHint {
        switch reason {
        case "calendar_not_authorized":
            return SourcePermissionHint(
                title: "Calendar access needed",
                body: "Calendar access is separate from Full Disk Access. Maraithon needs permission to read your events on this Mac. Open System Settings → Privacy & Security → Calendars, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
                settingsButtonTitle: "Open Calendar Settings",
                followUpNote: "After enabling Maraithon, return here and click Check again to recheck Calendar. If Maraithon is already listed, toggle it off and back on."
            )
        case "reminders_not_authorized":
            return SourcePermissionHint(
                title: "Reminders access needed",
                body: "Reminders access is separate from Full Disk Access. Maraithon needs permission to read reminders on this Mac. Open System Settings → Privacy & Security → Reminders, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"),
                settingsButtonTitle: "Open Reminders Settings",
                followUpNote: "After enabling Maraithon, return here and click Check again to recheck Reminders. If Maraithon is already listed, toggle it off and back on."
            )
        case "imessage_full_disk_access_required":
            return SourcePermissionHint(
                title: "iMessage access needed",
                body: "Maraithon needs Full Disk Access to read your local iMessage history on this Mac. One macOS grant covers iMessage, Notes, and Voice Memos; enable the Maraithon app you keep using, then click Check again.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                settingsButtonTitle: "Open Full Disk Access",
                followUpNote: FullDiskAccessCopy.unblockFollowUp,
                requiresStableFullDiskAccessApp: true
            )
        case "notes_full_disk_access_required":
            return SourcePermissionHint(
                title: "Notes access needed",
                body: "Maraithon needs Full Disk Access to read your local Notes on this Mac. One macOS grant covers iMessage, Notes, and Voice Memos; enable the Maraithon app you keep using, then click Check again.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                settingsButtonTitle: "Open Full Disk Access",
                followUpNote: FullDiskAccessCopy.unblockFollowUp,
                requiresStableFullDiskAccessApp: true
            )
        case "voice_memos_speech_disabled":
            return SourcePermissionHint(
                title: "Siri or Dictation is off",
                body: "Voice Memos can still be checked, but macOS is refusing local transcription because Siri or Dictation is disabled. Open System Settings → Apple Intelligence & Siri and turn Siri on, or open Keyboard → Dictation and turn Dictation on.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
                settingsButtonTitle: "Open Siri Settings",
                followUpNote: "After enabling Siri or Dictation, click Check again. New voice memos will get transcripts on the next check; existing memos update when they are checked again."
            )
        case "voice_memos_speech_not_authorized":
            return SourcePermissionHint(
                title: "Speech Recognition access needed",
                body: "Voice Memos can be checked, but transcripts need Speech Recognition permission. Open System Settings → Privacy & Security → Speech Recognition, then enable Maraithon.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"),
                settingsButtonTitle: "Open Speech Settings",
                followUpNote: "After enabling, click Check again. New voice memos will get transcripts on the next check."
            )
        case "voice_memos_full_disk_access_required":
            return SourcePermissionHint(
                title: "Voice Memos access needed",
                body: "Maraithon needs Full Disk Access to read your local Voice Memos and audio files on this Mac. One macOS grant covers iMessage, Notes, and Voice Memos; enable the Maraithon app you keep using, then click Check again.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                settingsButtonTitle: "Open Full Disk Access",
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

    static func hasFocusedUnblock(for reason: String) -> Bool {
        SourceState.isUserRecoverablePermissionReason(reason)
    }
}
