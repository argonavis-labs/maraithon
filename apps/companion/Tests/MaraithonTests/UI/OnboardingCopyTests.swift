import XCTest
@testable import Maraithon

final class OnboardingCopyTests: XCTestCase {
    func testContextScopeCopyFramesAssistantOutcomeInsteadOfSyncMechanics() {
        XCTAssertEqual(ContextScopeCopy.stepLabel, "Context")
        XCTAssertEqual(ContextScopeCopy.progressAccessibilityValue, "Step 2 of 4 — Assistant context")
        XCTAssertEqual(ContextScopeCopy.title, "Context your assistant can use")
        XCTAssertEqual(ContextScopeCopy.includedTitle, "Can be included")
        XCTAssertEqual(ContextScopeCopy.excludedTitle, "Never included")

        let publicCopy = [
            ContextScopeCopy.stepLabel,
            ContextScopeCopy.progressAccessibilityValue,
            ContextScopeCopy.title,
            ContextScopeCopy.body,
            ContextScopeCopy.includedTitle,
            ContextScopeCopy.excludedTitle
        ]
        .joined(separator: " ")

        XCTAssertTrue(publicCopy.localizedCaseInsensitiveContains("assistant"))
        XCTAssertTrue(publicCopy.localizedCaseInsensitiveContains("catch follow-ups"))
        XCTAssertFalse(publicCopy.localizedCaseInsensitiveContains("sync"))
        XCTAssertFalse(publicCopy.localizedCaseInsensitiveContains("crosses the line"))
    }

    func testContextScopeCopyNamesIncludedAndExcludedDataClearly() {
        XCTAssertEqual(
            ContextScopeCopy.includedItems,
            [
                "Messages",
                "Notes",
                "Voice Memos and transcripts",
                "Calendar",
                "Reminders",
                "Files in Documents",
                "Browser history"
            ]
        )

        XCTAssertEqual(
            ContextScopeCopy.excludedItems,
            [
                "Encrypted disks",
                "SSH keys and developer identities",
                "Developer secret files (.env)",
                "Banking and brokerage sites",
                "Medical portals",
                "Search engine queries"
            ]
        )

        let itemCopy = (ContextScopeCopy.includedItems + ContextScopeCopy.excludedItems)
            .joined(separator: " ")

        XCTAssertFalse(itemCopy.localizedCaseInsensitiveContains("~/Documents"))
        XCTAssertFalse(itemCopy.localizedCaseInsensitiveContains(".ssh"))
        XCTAssertFalse(itemCopy.localizedCaseInsensitiveContains("Voice Memos +"))
    }
}
