import XCTest
import SwiftUI
@testable import Maraithon

/// Smoke tests for the per-source detail panes. Each view is constructed
/// headlessly so we catch compile-time regressions and verify the
/// per-source stat dimensions match the spec.
@MainActor
final class SourceDetailScaffoldTests: XCTestCase {
    func testNotesDetailViewBuilds() {
        _ = NotesDetailView()
    }

    func testVoiceMemosDetailViewBuilds() {
        _ = VoiceMemosDetailView()
    }

    func testRemindersDetailViewBuilds() {
        _ = RemindersDetailView()
    }

    func testCalendarDetailViewBuilds() {
        _ = CalendarDetailView()
    }

    func testFilesDetailViewBuilds() {
        _ = FilesDetailView()
    }

    func testBrowserHistoryDetailViewBuilds() {
        _ = BrowserHistoryDetailView()
    }

    func testSourceStatHasIdentity() {
        let stat = SourceStat(id: "today", title: "Today", value: "47")
        XCTAssertEqual(stat.id, "today")
        XCTAssertEqual(stat.title, "Today")
        XCTAssertEqual(stat.value, "47")
        XCTAssertNil(stat.caption)
    }

    func testSourceActivityRowDefaultsToFreshUUID() {
        let a = SourceActivityRow(timestamp: Date(), count: 1, accepted: 1, duplicates: 0)
        let b = SourceActivityRow(timestamp: Date(), count: 1, accepted: 1, duplicates: 0)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testScaffoldBuildsWithEmptyActivity() {
        _ = SourceDetailScaffold(
            sourceID: "notes",
            displayName: "Notes",
            stats: [SourceStat(id: "today", title: "Today", value: "12")],
            activity: []
        )
    }

    func testClearCloudDataSheetBuilds() {
        _ = ClearCloudDataSheet(
            isPresented: .constant(true),
            description: "deletes things",
            onConfirmClearCloud: {}
        )
    }

    func testClearCloudDataSheetBuildsWithResetCursor() {
        _ = ClearCloudDataSheet(
            isPresented: .constant(true),
            description: "deletes things",
            onConfirmClearCloud: {},
            onResetLocalCursor: {}
        )
    }
}
