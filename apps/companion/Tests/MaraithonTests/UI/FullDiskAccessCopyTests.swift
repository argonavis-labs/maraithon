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

    func testInstallHintFlagsDerivedDataBuilds() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/Library/Developer/Xcode/DerivedData/Maraithon/Build/Products/Debug/Maraithon.app",
            isDirectory: true
        )

        let message = FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home)

        XCTAssertTrue(message?.contains("temporary development build") == true)
        XCTAssertTrue(message?.contains("~/Applications/Maraithon.app") == true)
        XCTAssertTrue(message?.contains("make run-companion") == true)
    }

    func testInstallHintFlagsSwiftPMBuilds() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = URL(
            fileURLWithPath: "/Users/operator/bliss/maraithon/apps/companion/.build/debug/Maraithon",
            isDirectory: false
        )

        XCTAssertNotNil(FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home))
    }

    func testInstallHintAllowsStableDevelopmentApp() {
        let home = URL(fileURLWithPath: "/Users/operator", isDirectory: true)
        let bundle = home
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)

        XCTAssertNil(FullDiskAccessInstallHint.message(for: bundle, homeDirectory: home))
    }
}
