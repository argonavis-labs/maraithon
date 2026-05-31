import XCTest
@testable import Maraithon

@MainActor
final class FullDiskAccessRequiredBannerTests: XCTestCase {
    func testTemporaryAppBannerExplainsWhyAccessDoesNotStick() {
        XCTAssertEqual(
            TemporaryFullDiskAccessAppBanner.titleText,
            "Use one app copy for Full Disk Access"
        )

        let copy = TemporaryFullDiskAccessAppBanner.detailText(stableAppInstalled: false)

        XCTAssertTrue(copy.contains("~/Applications/Maraithon.app"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("grant Full Disk Access once"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("reloads will keep using that permission"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("may reset"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("stable app"))
    }

    func testRepairActionCanRevealStableApp() {
        XCTAssertEqual(
            FullDiskAccessInstallHint.revealStableAppButtonTitle,
            "Show app copy"
        )
    }

    func testTemporaryAppBannerUsesSwitchCopyWhenStableAppExists() {
        let copy = TemporaryFullDiskAccessAppBanner.detailText(stableAppInstalled: true)

        XCTAssertTrue(copy.hasPrefix("Open ~/Applications/Maraithon.app"))
        XCTAssertFalse(copy.hasPrefix("Install ~/Applications/Maraithon.app"))
    }

    func testDetailTextUsesLiveBlockedSources() {
        let target = FullDiskAccessRequiredBanner.grantTargetCopy
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: ["iMessage", "Notes", "Voice Memos"]),
            "iMessage, Notes, and Voice Memos need one macOS Full Disk Access grant for \(target). Enable that exact app once; the rest of the app can keep checking."
        )
    }

    func testDetailTextUsesSingularVerbForOneBlockedSource() {
        let target = FullDiskAccessRequiredBanner.grantTargetCopy
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: ["iMessage"]),
            "iMessage needs one macOS Full Disk Access grant for \(target). Enable that exact app once; the rest of the app can keep checking."
        )
    }

    func testDetailTextUsesPluralVerbForTwoBlockedSources() {
        let target = FullDiskAccessRequiredBanner.grantTargetCopy
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: ["Notes", "Voice Memos"]),
            "Notes and Voice Memos need one macOS Full Disk Access grant for \(target). Enable that exact app once; the rest of the app can keep checking."
        )
    }

    func testDetailTextFallsBackWhenOnlyOnboardingSkipIsKnown() {
        let target = FullDiskAccessRequiredBanner.grantTargetCopy
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: []),
            "iMessage, Notes, and Voice Memos need one macOS Full Disk Access grant for \(target). Enable that exact app once; the rest of the app can keep checking."
        )
    }
}
