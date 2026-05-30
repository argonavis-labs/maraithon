import XCTest
@testable import Maraithon

@MainActor
final class FullDiskAccessRequiredBannerTests: XCTestCase {
    func testTemporaryAppBannerExplainsWhyAccessDoesNotStick() {
        XCTAssertEqual(
            TemporaryFullDiskAccessAppBanner.titleText,
            "Full Disk Access may reset after reloads"
        )

        let copy = TemporaryFullDiskAccessAppBanner.detailText(stableAppInstalled: false)

        XCTAssertTrue(copy.contains("~/Applications/Maraithon.app"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("persists across rebuilds"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("grant Full Disk Access there"))
    }

    func testRepairActionCanRevealStableApp() {
        XCTAssertEqual(
            FullDiskAccessInstallHint.revealStableAppButtonTitle,
            "Show Maraithon app"
        )
    }

    func testTemporaryAppBannerUsesSwitchCopyWhenStableAppExists() {
        let copy = TemporaryFullDiskAccessAppBanner.detailText(stableAppInstalled: true)

        XCTAssertTrue(copy.hasPrefix("Switch to the stable app"))
        XCTAssertFalse(copy.hasPrefix("Install the stable app"))
    }

    func testDetailTextUsesLiveBlockedSources() {
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: ["iMessage", "Notes", "Voice Memos"]),
            "iMessage, Notes, and Voice Memos need one macOS Full Disk Access grant. Enable Maraithon once; the rest of the app can keep syncing."
        )
    }

    func testDetailTextFallsBackWhenOnlyOnboardingSkipIsKnown() {
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: []),
            "iMessage, Notes, and Voice Memos need one macOS Full Disk Access grant. Enable Maraithon once; the rest of the app can keep syncing."
        )
    }
}
