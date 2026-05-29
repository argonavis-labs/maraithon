import XCTest
@testable import Maraithon

@MainActor
final class FullDiskAccessRequiredBannerTests: XCTestCase {
    func testDetailTextUsesLiveBlockedSources() {
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: ["iMessage", "Notes", "Voice Memos"]),
            "iMessage, Notes, and Voice Memos need one macOS Full Disk Access grant. Enable Maraithon once; other sources continue to sync."
        )
    }

    func testDetailTextFallsBackWhenOnlyOnboardingSkipIsKnown() {
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: []),
            "iMessage, Notes, and Voice Memos need one macOS Full Disk Access grant. Enable Maraithon once; other sources continue to sync."
        )
    }
}
