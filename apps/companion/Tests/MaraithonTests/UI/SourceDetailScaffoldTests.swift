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

    func testSourceDetailCountedItemUsesCorrectNoun() {
        XCTAssertEqual(
            SourceDetailCopy.countedItem(1, singular: "message", plural: "messages"),
            "1 message"
        )
        XCTAssertEqual(
            SourceDetailCopy.countedItem(12, singular: "message", plural: "messages"),
            "12 messages"
        )
    }

    func testHealthyHeadlineLeadsWithAssistantReadiness() {
        XCTAssertEqual(
            SourceDetailCopy.healthyHeadline(
                displayName: "iMessage",
                totalSynced: 0,
                singular: "message",
                plural: "messages"
            ),
            "Checking iMessage for assistant context"
        )
        let headline = SourceDetailCopy.healthyHeadline(
            displayName: "iMessage",
            totalSynced: 4,
            singular: "message",
            plural: "messages"
        )

        XCTAssertEqual(headline, "iMessage is available to your assistant")
        XCTAssertFalse(headline.localizedCaseInsensitiveContains("messages synced"))
        XCTAssertFalse(headline.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(headline.localizedCaseInsensitiveContains("connected"))
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
            "Last check added 4 messages, bringing 12 messages into assistant context. Your assistant will keep this context current. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("accepted"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("duplicate"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("connected"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("last check added"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("assistant context"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("everything is current"))
    }

    func testConnectedSummaryWithoutLastCheckStaysAssistantCentric() {
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "iMessage",
            totalSynced: 12,
            lastCheckSynced: 0,
            lastCheckAlreadySynced: 0,
            lastCheckNotSynced: 0,
            lastSyncAt: nil,
            singular: "message",
            plural: "messages"
        )

        XCTAssertEqual(
            copy,
            "Your assistant has 12 messages available. Check now to look for anything new."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("has synced"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("Maraithon can use"))
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
            "No new messages since the last check. Your assistant will keep this context current. Checked just now."
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
            "No new messages since the last check. Your assistant will keep this context current. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("Synced 4 messages."))
    }

    func testConnectedSummaryScopesEmptyHealthyCheckBeforeAnyContext() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let copy = SourceDetailCopy.connectedSummary(
            displayName: "iMessage",
            totalSynced: 0,
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
            "Last check did not add any messages to assistant context yet. Maraithon will keep checking. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("found"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("connected"))
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
            "Last check added 3 notes, bringing 8 notes into assistant context. 1 note needs attention. Checked just now."
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
        XCTAssertEqual(SourceDetailCopy.privacySectionTitle, "Privacy guardrails")
        XCTAssertEqual(SourceDetailCopy.activitySectionTitle, "Activity")
        XCTAssertEqual(SourceDetailCopy.recentChecksSectionTitle, "Recent checks")
        XCTAssertEqual(SourceDetailCopy.lastCheckTitle, "Last check")
        XCTAssertEqual(SourceDetailCopy.lastBatchSyncedCaption, "new this check")
        XCTAssertEqual(SourceDetailCopy.alreadySyncedTitle, "Already known")
        XCTAssertEqual(SourceDetailCopy.alreadySyncedCaption, "last check")
        XCTAssertEqual(SourceDetailCopy.notSyncedTitle, "Needs attention")
        XCTAssertEqual(SourceDetailCopy.notSyncedCaption, "last check")
        XCTAssertEqual(SourceDetailCopy.totalSyncedTitle, "Assistant context")
        XCTAssertEqual(SourceDetailCopy.totalSyncedCaption, "available now")
        XCTAssertEqual(SourceDetailCopy.lastSyncTitle, "Last checked")
        XCTAssertEqual(SourceDetailCopy.lastSyncCaption, "successful check")
        XCTAssertEqual(SourceDetailCopy.firstSyncTitle, "Ready for first sync")
        XCTAssertEqual(SourceDetailCopy.issueErrorTitle, "Last check failed")
        XCTAssertEqual(SourceDetailCopy.resetSourceButtonTitle, "Check from the beginning")
        XCTAssertEqual(SourceDetailCopy.issueAttentionTitle(plural: "messages"), "Some messages need attention")
        XCTAssertEqual(SourceDetailCopy.failedItemsLine(1, singular: "message", plural: "messages"), "1 message needs another check.")
        XCTAssertEqual(SourceDetailCopy.failedItemsLine(3, singular: "message", plural: "messages"), "3 messages need another check.")
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

    func testIMessagesPrivacyNotesExplainUserControl() {
        let notes = SourceDetailCopy.privacyNotes(for: "imessage", displayName: "iMessage")
        let text = notes.map { "\($0.title) \($0.description)" }.joined(separator: " ")

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes.map(\.title), [
            "Local filtering",
            "Encrypted sync",
            "Device control"
        ])
        XCTAssertTrue(text.localizedCaseInsensitiveContains("filtered on this Mac"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("encrypted on this Mac"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("delete synced Messages data"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("server"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("database"))
    }

    func testKnownSourcePrivacyNotesStayUserFacing() {
        for sourceID in ["calendar", "notes", "reminders", "voice_memos", "files", "browser_history"] {
            let notes = SourceDetailCopy.privacyNotes(for: sourceID, displayName: sourceID)
            let text = notes.map { "\($0.title) \($0.description)" }.joined(separator: " ")

            XCTAssertEqual(notes.count, 3, sourceID)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("this Mac"), sourceID)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("delete synced"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("server"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("database"), sourceID)
        }
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
        XCTAssertTrue(copy.contains("ready to check Notes"))
        XCTAssertTrue(copy.contains("assistant context"))
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
        XCTAssertEqual(
            SourceDetailCopy.relativeSyncTime(now.addingTimeInterval(120), relativeTo: now),
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
