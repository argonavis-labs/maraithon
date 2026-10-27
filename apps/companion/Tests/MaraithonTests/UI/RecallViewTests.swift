import XCTest
@testable import Maraithon

@MainActor
final class RecallViewTests: XCTestCase {
    func testRecallViewBuilds() {
        _ = RecallView()
    }

    func testRecallCopyStaysAssistantContextFocused() {
        XCTAssertEqual(RecallCopy.searchButtonTitle, "Search")
        XCTAssertEqual(RecallCopy.noMatchesTitle, "No matching context available")

        let emptyDescription = RecallCopy.noMatchesDescription(for: "")
        XCTAssertTrue(emptyDescription.contains("context already available to your assistant"))
        XCTAssertFalse(emptyDescription.localizedCaseInsensitiveContains("database"))
        XCTAssertFalse(emptyDescription.localizedCaseInsensitiveContains("embedding"))

        let queryDescription = RecallCopy.noMatchesDescription(for: "Matthew pricing")
        XCTAssertTrue(queryDescription.contains("\"Matthew pricing\""))
        XCTAssertTrue(queryDescription.contains("person, thread, phrase, or date"))
    }

    func testRecallSourceLabelsAreHumanReadable() {
        XCTAssertEqual(RecallCopy.sourceLabel(for: "local_messages"), "Messages")
        XCTAssertEqual(RecallCopy.sourceLabel(for: "local_browser_history"), "Browser History")
        XCTAssertEqual(RecallCopy.sourceLabel(for: "crm_people"), "Contacts")
        XCTAssertEqual(RecallCopy.sourceLabel(for: "local_unknown_source"), "Unknown Source")
    }
}
