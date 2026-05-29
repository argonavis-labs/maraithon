import XCTest
@testable import Maraithon

@MainActor
final class FullDiskAccessRequiredBannerTests: XCTestCase {
    func testDetailTextUsesLiveBlockedSources() {
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: ["iMessage", "Notes", "Voice Memos"]),
            "iMessage, Notes, and Voice Memos cannot sync until Maraithon is enabled in Full Disk Access. Other sources continue to sync."
        )
    }

    func testDetailTextFallsBackWhenOnlyOnboardingSkipIsKnown() {
        XCTAssertEqual(
            FullDiskAccessRequiredBanner.detailText(blockedSourceNames: []),
            "iMessage, Notes, and Voice Memos cannot sync until Maraithon is enabled in Full Disk Access. Other sources continue to sync."
        )
    }
}
