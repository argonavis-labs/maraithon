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

    func testSourceDetailHeadlineUsesItemNounInsteadOfSourceName() {
        XCTAssertEqual(
            SourceDetailCopy.syncedHeadline(total: 1, singular: "message", plural: "messages"),
            "1 message synced"
        )
        XCTAssertEqual(
            SourceDetailCopy.syncedHeadline(total: 12, singular: "message", plural: "messages"),
            "12 messages synced"
        )
    }

    func testConnectedSummaryExplainsLastCheckOutcome() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "iMessage",
            totalSynced: 12,
            lastCheckSynced: 4,
            lastCheckAlreadySynced: 0,
            lastCheckNotSynced: 0,
            lastSyncAt: now,
            singular: "message",
            plural: "messages",
            relativeTo: now
        )

        XCTAssertEqual(
            copy,
            "Synced 4 messages. Everything is current. Automatic checks are on. Last sync just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("accepted"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("duplicate"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("last check"))
    }

    func testConnectedSummaryExplainsNoNewItems() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "iMessage",
            totalSynced: 4,
            lastCheckSynced: 0,
            lastCheckAlreadySynced: 4,
            lastCheckNotSynced: 0,
            lastSyncAt: now,
            singular: "message",
            plural: "messages",
            relativeTo: now
        )

        XCTAssertEqual(
            copy,
            "No new messages found. Everything is current. Automatic checks are on. Last sync just now."
        )
    }

    func testConnectedSummaryExplainsEmptyHealthyCheckAfterPriorSync() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "iMessage",
            totalSynced: 4,
            lastCheckSynced: 0,
            lastCheckAlreadySynced: 0,
            lastCheckNotSynced: 0,
            lastSyncAt: now,
            singular: "message",
            plural: "messages",
            relativeTo: now
        )

        XCTAssertEqual(
            copy,
            "No new messages found. Everything is current. Automatic checks are on. Last sync just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("Synced 4 messages."))
    }

    func testConnectedSummaryUsesAttentionCopyForPartialFailures() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "Notes",
            totalSynced: 8,
            lastCheckSynced: 3,
            lastCheckAlreadySynced: 0,
            lastCheckNotSynced: 1,
            lastSyncAt: now,
            singular: "note",
            plural: "notes",
            relativeTo: now
        )

        XCTAssertEqual(
            copy,
            "Synced 3 notes. 1 note needs attention. Last sync just now."
        )
    }

    func testSourceDetailMetricCopyAvoidsSyncEngineVocabulary() {
        XCTAssertEqual(SourceDetailCopy.lastCheckTitle, "Last check")
        XCTAssertEqual(SourceDetailCopy.lastBatchSyncedCaption, "synced")
        XCTAssertEqual(SourceDetailCopy.alreadySyncedTitle, "Already synced")
        XCTAssertEqual(SourceDetailCopy.alreadySyncedCaption, "last check")
        XCTAssertEqual(SourceDetailCopy.notSyncedTitle, "Not synced")
        XCTAssertEqual(SourceDetailCopy.notSyncedCaption, "last check")
        XCTAssertEqual(SourceDetailCopy.lastSyncTitle, "Last sync")
        XCTAssertEqual(SourceDetailCopy.lastSyncCaption, "successful check")
        XCTAssertEqual(SourceDetailCopy.firstSyncTitle, "Ready for first sync")
    }

    func testFirstSyncCopyDoesNotClaimDisconnectedSourcesAreConnected() {
        XCTAssertTrue(SourceDetailCopy.isWaitingForFirstSync(state: .connected, lastSyncAt: nil))
        XCTAssertFalse(SourceDetailCopy.isWaitingForFirstSync(state: .disconnected, lastSyncAt: nil))
        XCTAssertFalse(SourceDetailCopy.isWaitingForFirstSync(state: .syncing, lastSyncAt: nil))
        XCTAssertFalse(SourceDetailCopy.isWaitingForFirstSync(state: .connected, lastSyncAt: Date()))

        let copy = SourceDetailCopy.firstSyncDescription(displayName: "Notes")
        XCTAssertTrue(copy.contains("ready to sync Notes"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("Notes is connected"))
    }

    func testSourceDetailRelativeSyncTimeDoesNotSayInZeroSeconds() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        XCTAssertEqual(
            SourceDetailCopy.relativeSyncTime(now, relativeTo: now),
            "just now"
        )
        XCTAssertEqual(
            SourceDetailCopy.relativeSyncTime(now.addingTimeInterval(20), relativeTo: now),
            "just now"
        )
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
