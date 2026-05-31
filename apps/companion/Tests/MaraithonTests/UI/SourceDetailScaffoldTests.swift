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

    func testSourceStatRowBuilds() {
        _ = SourceStatRow(
            stat: SourceStat(
                id: "last_sync",
                title: "Last checked",
                value: "just now",
                caption: "successful check"
            )
        )
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
            "iMessage is ready for its first check"
        )
        let headline = SourceDetailCopy.healthyHeadline(
            displayName: "iMessage",
            totalSynced: 4,
            singular: "message",
            plural: "messages"
        )

        XCTAssertEqual(headline, "iMessage context is ready")
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
            "Added 4 messages on the last check. Your assistant now has 12 messages available. Maraithon will keep checking for new context. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("accepted"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("duplicate"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("connected"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("added 4 messages on the last check"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("assistant now has"))
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
            "No new iMessage context on the last check. Your assistant still has 4 messages available. Maraithon will keep checking for new context. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("No new messages"))
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
            "No new iMessage context on the last check. Your assistant still has 4 messages available. Maraithon will keep checking for new context. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("Synced 4 messages."))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("No new messages"))
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
            "No iMessage context was available on the last check. Maraithon will keep checking. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("No new messages"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("this session"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("connected"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("yet"))
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
            "Added 3 notes on the last check. Your assistant now has 8 notes available. 1 note needs another check. Checked just now."
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
            "Last check found 1 message that needs another check. Maraithon will retry on the next check. Checked just now."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("No new messages found"))
    }

    func testSourceDetailMetricCopyAvoidsSyncEngineVocabulary() {
        XCTAssertEqual(SourceDetailCopy.capabilitiesSectionTitle, "What your assistant can use")
        XCTAssertEqual(SourceDetailCopy.privacySectionTitle, "Control and privacy")
        XCTAssertEqual(SourceDetailCopy.activitySectionTitle, "Available context")
        XCTAssertEqual(SourceDetailCopy.recentChecksSectionTitle, "Check history")
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
        XCTAssertEqual(SourceDetailCopy.checkNowButtonTitle, "Check now")
        XCTAssertEqual(SourceDetailCopy.resumeUpdatesButtonTitle, "Resume updates")
        XCTAssertEqual(SourceDetailCopy.pauseUpdatesButtonTitle, "Pause updates")
        XCTAssertEqual(SourceDetailCopy.firstSyncTitle, "Ready for first check")
        XCTAssertEqual(SourceDetailCopy.issueErrorTitle, "Last check failed")
        XCTAssertEqual(SourceDetailCopy.resetSourceButtonTitle, "Check from the beginning")
        XCTAssertEqual(SourceDetailCopy.pausedHeadline(displayName: "iMessage"), "iMessage updates are paused")
        XCTAssertEqual(
            SourceDetailCopy.pausedSummary(displayName: "iMessage", plural: "messages"),
            "Resume updates when you want iMessage to check for new messages again."
        )
        XCTAssertEqual(
            SourceDetailCopy.unavailablePublisherSummary(displayName: "iMessage"),
            "Open Maraithon on this Mac to make iMessage available to your assistant."
        )
        XCTAssertEqual(SourceDetailCopy.errorHeadline(displayName: "iMessage"), "iMessage could not be checked")
        XCTAssertEqual(SourceDetailCopy.disconnectedHeadline(displayName: "iMessage"), "iMessage is not updating")
        XCTAssertEqual(SourceDetailCopy.issueAttentionTitle(plural: "messages"), "Some messages need attention")
        XCTAssertEqual(SourceDetailCopy.failedItemsLine(1, singular: "message", plural: "messages"), "1 message needs another check.")
        XCTAssertEqual(SourceDetailCopy.failedItemsLine(3, singular: "message", plural: "messages"), "3 messages need another check.")

        let statusCopy = [
            SourceDetailCopy.resumeUpdatesButtonTitle,
            SourceDetailCopy.firstSyncTitle,
            SourceDetailCopy.issueErrorTitle,
            SourceDetailCopy.pausedHeadline(displayName: "iMessage"),
            SourceDetailCopy.pausedSummary(displayName: "iMessage", plural: "messages"),
            SourceDetailCopy.errorHeadline(displayName: "iMessage"),
            SourceDetailCopy.disconnectedHeadline(displayName: "iMessage")
        ].joined(separator: " ")
        XCTAssertFalse(statusCopy.localizedCaseInsensitiveContains("sync"))
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
        XCTAssertTrue(text.localizedCaseInsensitiveContains("keeps approval with you"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("this session"))
    }

    func testIMessagesPrivacyNotesExplainUserControl() {
        let notes = SourceDetailCopy.privacyNotes(for: "imessage", displayName: "iMessage")
        let text = notes.map { "\($0.title) \($0.description)" }.joined(separator: " ")

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes.map(\.title), [
            "Local filtering",
            "Encrypted transfer",
            "Device control"
        ])
        XCTAssertTrue(text.localizedCaseInsensitiveContains("filtered on this Mac"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("encrypted on this Mac"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("delete Maraithon's copy of Messages data"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("server"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("database"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("upload"))
    }

    func testKnownSourcePrivacyNotesStayUserFacing() {
        for sourceID in ["calendar", "notes", "reminders", "voice_memos", "files", "browser_history"] {
            let notes = SourceDetailCopy.privacyNotes(for: sourceID, displayName: sourceID)
            let text = notes.map { "\($0.title) \($0.description)" }.joined(separator: " ")

            XCTAssertEqual(notes.count, 3, sourceID)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("this Mac"), sourceID)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("delete Maraithon's copy"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("server"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("database"), sourceID)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("upload"), sourceID)
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
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("not finished yet"))
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
