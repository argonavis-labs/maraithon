import XCTest
@testable import Maraithon

final class FullDiskAccessCopyTests: XCTestCase {
    func testOnboardingCopyNamesAllBlockedLocalSources() {
        XCTAssertEqual(
            FullDiskAccessCopy.onboardingTitle,
            "Allow Maraithon to read local sources"
        )
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("iMessage"))
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("Notes"))
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("Voice Memos"))
        XCTAssertTrue(FullDiskAccessCopy.onboardingBody.contains("read-only"))
        XCTAssertFalse(FullDiskAccessCopy.onboardingBody.localizedCaseInsensitiveContains("database is"))
    }

    func testOnboardingActionsAvoidSingleSourceSetupLanguage() {
        XCTAssertEqual(FullDiskAccessCopy.openSettingsButton, "Open System Settings")
        XCTAssertEqual(FullDiskAccessCopy.continueButton, "Continue")
        XCTAssertEqual(FullDiskAccessCopy.skipButton, "Set up local sources later")
        XCTAssertFalse(FullDiskAccessCopy.skipButton.localizedCaseInsensitiveContains("iMessage"))
    }

    func testUnblockFollowUpDoesNotRequireARestart() {
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("updates automatically"))
        XCTAssertTrue(FullDiskAccessCopy.unblockFollowUp.contains("Check again"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("quit"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("reopen"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("restart"))
        XCTAssertFalse(FullDiskAccessCopy.unblockFollowUp.localizedCaseInsensitiveContains("relaunch"))
    }
}
