import XCTest
@testable import Maraithon

/// The unblock view picks copy + a deep link from `SourcePermissionHint`.
/// These tests pin the two reasons currently emitted by real sources
/// and verify the fallback for an unknown reason.
final class SourcePermissionHintTests: XCTestCase {
    func testCalendarReasonHasSettingsDeepLink() {
        let hint = SourcePermissionHint.forReason("calendar_not_authorized")
        XCTAssertEqual(hint.title, "Calendar access needed")
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        )
        XCTAssertNotNil(hint.followUpNote)
    }

    func testRemindersReasonHasSettingsDeepLink() {
        let hint = SourcePermissionHint.forReason("reminders_not_authorized")
        XCTAssertEqual(hint.title, "Reminders access needed")
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        )
    }

    func testVoiceMemosFullDiskAccessReasonHasSettingsDeepLink() {
        let hint = SourcePermissionHint.forReason("voice_memos_full_disk_access_required")
        XCTAssertEqual(hint.title, "Voice Memos access needed")
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        XCTAssertEqual(hint.followUpNote, FullDiskAccessCopy.unblockFollowUp)
        XCTAssertTrue(hint.requiresStableFullDiskAccessApp)
    }

    func testMessagesFullDiskAccessReasonHasSettingsDeepLink() {
        let hint = SourcePermissionHint.forReason("imessage_full_disk_access_required")
        XCTAssertEqual(hint.title, "iMessage access needed")
        XCTAssertTrue(hint.body.contains("iMessage history"))
        XCTAssertFalse(hint.body.localizedCaseInsensitiveContains("database"))
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        XCTAssertEqual(hint.followUpNote, FullDiskAccessCopy.unblockFollowUp)
        XCTAssertTrue(hint.requiresStableFullDiskAccessApp)
    }

    func testNotesFullDiskAccessReasonHasSettingsDeepLink() {
        let hint = SourcePermissionHint.forReason("notes_full_disk_access_required")
        XCTAssertEqual(hint.title, "Notes access needed")
        XCTAssertTrue(hint.body.contains("local Notes"))
        XCTAssertFalse(hint.body.localizedCaseInsensitiveContains("database"))
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        XCTAssertEqual(hint.followUpNote, FullDiskAccessCopy.unblockFollowUp)
        XCTAssertTrue(hint.requiresStableFullDiskAccessApp)
    }

    func testVoiceMemosSpeechDisabledReasonPointsToSiriSettings() {
        let hint = SourcePermissionHint.forReason("voice_memos_speech_disabled")
        XCTAssertEqual(hint.title, "Siri or Dictation is off")
        XCTAssertTrue(hint.body.contains("Apple Intelligence & Siri"))
        XCTAssertTrue(hint.body.contains("Keyboard → Dictation"))
        XCTAssertFalse(hint.body.contains("Privacy & Security → Speech Recognition"))
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        )
        XCTAssertNotNil(hint.followUpNote)
        XCTAssertFalse(hint.requiresStableFullDiskAccessApp)
    }

    func testUnknownReasonFallsBackToSanitizedGenericWithoutDeepLink() {
        let hint = SourcePermissionHint.forReason("something_weird")
        XCTAssertEqual(hint.title, "This source needs attention")
        XCTAssertEqual(hint.body, "This source needs attention. Open the source detail before syncing again.")
        XCTAssertNil(hint.settingsURL)
        XCTAssertNil(hint.followUpNote)
        XCTAssertFalse(hint.requiresStableFullDiskAccessApp)
    }
}
