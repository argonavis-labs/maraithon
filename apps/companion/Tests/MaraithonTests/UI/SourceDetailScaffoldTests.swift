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

    func testHealthyHeadlineLeadsWithOutcomeCount() {
        XCTAssertEqual(
            SourceDetailCopy.healthyHeadline(
                displayName: "iMessage",
                totalSynced: 0,
                singular: "message",
                plural: "messages"
            ),
            "Maraithon is keeping iMessage current"
        )
        XCTAssertEqual(
            SourceDetailCopy.healthyHeadline(
                displayName: "iMessage",
                totalSynced: 4,
                singular: "message",
                plural: "messages"
            ),
            "4 messages synced"
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
            "Last check found and synced 4 messages. Maraithon will keep checking in the background. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("accepted"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("duplicate"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("found and synced"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("everything is current"))
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
            "No new messages found. Maraithon will keep checking in the background. Checked just now."
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
            "No new messages found. Maraithon will keep checking in the background. Checked just now."
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
            "Last check found and synced 3 notes. 1 note needs attention. Checked just now."
        )
    }

    func testConnectedSummaryDoesNotClaimNothingWasFoundWhenOnlyFailuresNeedAttention() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "iMessage",
            totalSynced: 12,
            lastCheckSynced: 0,
            lastCheckAlreadySynced: 4,
            lastCheckNotSynced: 1,
            lastSyncAt: now,
            singular: "message",
            plural: "messages",
            relativeTo: now
        )

        XCTAssertEqual(
            copy,
            "Last check found 1 message that needs attention. Maraithon will retry on the next check. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("No new messages found"))
    }

    func testSourceDetailMetricCopyAvoidsSyncEngineVocabulary() {
        XCTAssertEqual(SourceDetailCopy.capabilitiesSectionTitle, "Assistant coverage")
        XCTAssertEqual(SourceDetailCopy.activitySectionTitle, "Activity")
        XCTAssertEqual(SourceDetailCopy.recentChecksSectionTitle, "Recent checks")
        XCTAssertEqual(SourceDetailCopy.lastCheckTitle, "Last check")
        XCTAssertEqual(SourceDetailCopy.lastBatchSyncedCaption, "synced")
        XCTAssertEqual(SourceDetailCopy.alreadySyncedTitle, "Already known")
        XCTAssertEqual(SourceDetailCopy.alreadySyncedCaption, "last check")
        XCTAssertEqual(SourceDetailCopy.notSyncedTitle, "Needs attention")
        XCTAssertEqual(SourceDetailCopy.notSyncedCaption, "last check")
        XCTAssertEqual(SourceDetailCopy.totalSyncedTitle, "Total synced")
        XCTAssertEqual(SourceDetailCopy.totalSyncedCaption, "all time")
        XCTAssertEqual(SourceDetailCopy.lastSyncTitle, "Last checked")
        XCTAssertEqual(SourceDetailCopy.lastSyncCaption, "successful check")
        XCTAssertEqual(SourceDetailCopy.firstSyncTitle, "Ready for first sync")
    }

    func testIMessagesCapabilitiesNameChiefOfStaffOutcomes() {
        let capabilities = SourceDetailCopy.capabilities(for: "imessage", displayName: "iMessage")
        let text = capabilities.map { "\($0.title) \($0.description)" }.joined(separator: " ")

        XCTAssertEqual(capabilities.count, 3)
        XCTAssertEqual(capabilities.map(\.title), [
            "People and threads",
            "Reply obligations",
            "Reply prep"
        ])
        XCTAssertTrue(text.localizedCaseInsensitiveContains("source evidence"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("approval loop"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("this session"))
    }

    func testKnownSourceCapabilitiesStayOutcomeOriented() {
        for sourceID in ["calendar", "notes", "reminders", "voice_memos", "files", "browser_history"] {
            let capabilities = SourceDetailCopy.capabilities(for: sourceID, displayName: sourceID)
            let text = capabilities.map { "\($0.title) \($0.description)" }.joined(separator: " ")

            XCTAssertEqual(capabilities.count, 3, sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("accepted"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("duplicate"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("batch"), sourceID)
        }
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
