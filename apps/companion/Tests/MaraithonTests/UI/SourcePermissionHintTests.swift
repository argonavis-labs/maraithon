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
        XCTAssertNotNil(hint.relaunchNote)
    }

    func testRemindersReasonHasSettingsDeepLink() {
        let hint = SourcePermissionHint.forReason("reminders_not_authorized")
        XCTAssertEqual(hint.title, "Reminders access needed")
        XCTAssertEqual(
            hint.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        )
    }

    func testUnknownReasonFallsBackToGenericWithoutDeepLink() {
        let hint = SourcePermissionHint.forReason("something_weird")
        XCTAssertEqual(hint.title, "This source needs attention")
        XCTAssertEqual(hint.body, "something_weird")
        XCTAssertNil(hint.settingsURL)
        XCTAssertNil(hint.relaunchNote)
    }
}
