import XCTest
import SwiftUI
@testable import Maraithon

/// Smoke tests for UI primitives. These verify the value-only surface of
/// the components (state vocabulary, derived labels, etc.) without
/// rendering — SwiftUI snapshot testing is a follow-up.
final class UIComponentsTests: XCTestCase {
    @MainActor
    func testSourceStatusBadgeSymbolsCoverAllStates() {
        let states: [SourceStatusBadge.State] = [
            .connected,
            .syncing,
            .paused,
            .needsAttention("reason"),
            .disconnected,
            .error("boom")
        ]

        let symbols = Set(states.map(\.symbol))
        XCTAssertEqual(symbols.count, states.count, "Every state needs a distinct SF Symbol")
    }

    @MainActor
    func testSourceStatusBadgeSubtitleUsesDisplayCopy() {
        let attn = SourceStatusBadge.State.needsAttention("voice_memos_full_disk_access_required")
        XCTAssertEqual(attn.subtitle, "Full Disk Access is required.")

        let err = SourceStatusBadge.State.error("clientError(status: 401, body: nil)")
        XCTAssertEqual(err.subtitle, "Reconnect Maraithon to resume sync.")

        XCTAssertNil(SourceStatusBadge.State.connected.subtitle)
    }

    @MainActor
    func testSourceStatusBadgeUsesTrafficLightTones() {
        XCTAssertEqual(SourceStatusBadge.State.connected.tone, .good)
        XCTAssertEqual(SourceStatusBadge.State.syncing.tone, .good)
        XCTAssertEqual(SourceStatusBadge.State.needsAttention("partial").tone, .attention)
        XCTAssertEqual(SourceStatusBadge.State.disconnected.tone, .error)
        XCTAssertEqual(SourceStatusBadge.State.error("failed").tone, .error)
    }

    @MainActor
    func testHealthySourceCopyUsesOutcomeLanguage() {
        XCTAssertEqual(SourceStatusBadge.State.connected.label, "Up to date")

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let label = SourceRowCopy.accessibilityLabel(
            sourceName: "iMessage",
            comingSoon: false,
            rawState: .connected,
            displayedState: .connected,
            lastSyncAt: now.addingTimeInterval(-120),
            now: now
        )

        XCTAssertEqual(label, "iMessage, up to date, last checked 2m ago")
        XCTAssertFalse(label.localizedCaseInsensitiveContains("connected"))
    }

    @MainActor
    func testSourceRowAssistiveCopyDoesNotLeakRawIssueDetails() {
        let raw = "clientError(status: 400, body: Optional(\"{\\\"error\\\":\\\"invalid_batch\\\",\\\"secret\\\":\\\"abc\\\"}\"))"

        let label = SourceRowCopy.accessibilityLabel(
            sourceName: "Notes",
            comingSoon: false,
            rawState: .error(reason: raw),
            displayedState: .error(reason: raw),
            lastSyncAt: nil
        )
        let tooltip = SourceRowCopy.tooltip(
            comingSoon: false,
            state: .connected,
            activeIssueReason: raw,
            lastSyncAt: nil
        )

        XCTAssertEqual(label, "Notes, error, Some items could not finish syncing. Maraithon will keep the last successful data until the next sync.")
        XCTAssertEqual(tooltip, "Some items could not finish syncing. Maraithon will keep the last successful data until the next sync.")
        XCTAssertFalse(label.contains("secret"))
        XCTAssertFalse(tooltip.contains("secret"))
        XCTAssertFalse(label.contains("clientError"))
        XCTAssertFalse(tooltip.contains("clientError"))
    }

    @MainActor
    func testSourceRowUnavailableCopyIsNotReportedAsDisconnected() {
        XCTAssertEqual(
            SourceRowCopy.accessibilityLabel(
                sourceName: "Files",
                comingSoon: true,
                rawState: .disconnected,
                displayedState: .disconnected,
                lastSyncAt: nil
            ),
            "Files, not available yet"
        )

        XCTAssertEqual(
            SourceRowCopy.tooltip(
                comingSoon: true,
                state: .disconnected,
                activeIssueReason: nil,
                lastSyncAt: nil
            ),
            "Source not available yet"
        )
    }

    @MainActor
    func testSourceRowTrailingStatusUsesActionableCopy() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        XCTAssertEqual(
            SourceRowCopy.trailingStatus(
                rawState: .needsAttention(reason: "imessage_full_disk_access_required"),
                displayedState: .needsAttention(reason: "imessage_full_disk_access_required"),
                lastSyncAt: nil,
                now: now
            ),
            "Fix"
        )
        XCTAssertEqual(
            SourceRowCopy.trailingStatus(
                rawState: .error(reason: "serverError(status: 503)"),
                displayedState: .error(reason: "serverError(status: 503)"),
                lastSyncAt: nil,
                now: now
            ),
            "Fix"
        )
        XCTAssertEqual(
            SourceRowCopy.trailingStatus(
                rawState: .connected,
                displayedState: .disconnected,
                lastSyncAt: nil,
                now: now
            ),
            "Waiting"
        )
        XCTAssertEqual(
            SourceRowCopy.trailingStatus(
                rawState: .disconnected,
                displayedState: .disconnected,
                lastSyncAt: nil,
                now: now
            ),
            "Set up"
        )
        XCTAssertEqual(
            SourceRowCopy.trailingStatus(
                rawState: .connected,
                displayedState: .connected,
                lastSyncAt: now.addingTimeInterval(-2 * 60 * 60),
                now: now
            ),
            "2hr"
        )
    }

    func testUnavailableSourceDetailCopyAvoidsRoadmapLanguage() {
        XCTAssertEqual(SourceAvailabilityCopy.unavailableTitle, "Source not available yet")
        XCTAssertEqual(SourceAvailabilityCopy.unavailableNavigationTitle, "Not available yet")
        XCTAssertEqual(SourceAvailabilityCopy.unavailableBadge, "Soon")
        XCTAssertTrue(SourceAvailabilityCopy.unavailableDescription.contains("supported source"))
        XCTAssertFalse(SourceAvailabilityCopy.unavailableDescription.localizedCaseInsensitiveContains("iMessage is stable"))
        XCTAssertFalse(SourceAvailabilityCopy.unavailableDescription.localizedCaseInsensitiveContains("coming soon"))
    }

    @MainActor
    func testDiagnosticsSettingsCopyDoesNotExposeRawPublisherState() {
        let publisher = SourceStatusPublisher(state: .connected)
        let raw = "clientError(status: 500, body: Optional(\"token=secret stacktrace\"))"
        publisher.recordCycleFailure(at: Date(timeIntervalSince1970: 1_780_000_000), reason: raw)

        let line = DiagnosticsSettingsCopy.stateLine(publisher: publisher)

        XCTAssertTrue(line.contains("Status: Error - Maraithon is temporarily unavailable. Sync again shortly."))
        XCTAssertTrue(line.contains("Last checked: Never"))
        XCTAssertFalse(line.contains("state="))
        XCTAssertFalse(line.contains("clientError"))
        XCTAssertFalse(line.contains("token=secret"))
        XCTAssertFalse(line.lowercased().contains("stacktrace"))
    }

    @MainActor
    func testDiagnosticsSettingsCopyKeepsDeveloperCopyReadable() {
        let publicCopy = [
            DiagnosticsSettingsCopy.intro,
            DiagnosticsSettingsCopy.developerModeDescription
        ].joined(separator: " ")

        XCTAssertFalse(publicCopy.lowercased().contains("publisher"))
        XCTAssertFalse(publicCopy.lowercased().contains("cursor"))
        XCTAssertFalse(publicCopy.lowercased().contains("ring buffer"))
        XCTAssertTrue(publicCopy.contains("sync health"))
    }

    @MainActor
    func testDiagnosticsSettingsBatchLineAvoidsDebugShorthand() {
        let event = SourceStatusPublisher.BatchEvent(
            timestamp: Date(),
            accepted: 7,
            duplicate: 2,
            failed: 1,
            latencyMS: 42
        )

        let line = DiagnosticsSettingsCopy.batchLine(event)

        XCTAssertEqual(line, "Synced 7 | Already known 2 | Needs attention 1 | 42 ms")
        XCTAssertFalse(line.contains("accepted="))
        XCTAssertFalse(line.contains("dup="))
        XCTAssertFalse(line.contains("failed="))
        XCTAssertFalse(line.contains("lat="))
        XCTAssertFalse(line.contains("Accepted"))
        XCTAssertFalse(line.contains("Duplicates"))
        XCTAssertFalse(line.contains("Not synced"))
    }

    func testDataSettingsCopyUsesExplicitUserActions() {
        let publicCopy = [
            DataSettingsCopy.intro,
            DataSettingsCopy.resyncTitle,
            DataSettingsCopy.deleteTitle,
            DataSettingsCopy.deleteAllTitle,
            DataSettingsCopy.deleteAllDescription,
            DataSettingsCopy.deleteAllConfirmation,
            DataSettingsCopy.sourceDeleteConfirmation(sourceName: "iMessage")
        ].joined(separator: " ")

        XCTAssertTrue(publicCopy.contains("Re-sync"))
        XCTAssertTrue(publicCopy.contains("Delete"))
        XCTAssertFalse(publicCopy.lowercased().contains("clear cloud"))
        XCTAssertFalse(publicCopy.lowercased().contains("wipes"))
        XCTAssertFalse(publicCopy.lowercased().contains("server"))
        XCTAssertFalse(publicCopy.lowercased().contains("reset is safe"))
    }

    func testPrivacySettingsCopyExplainsEncryptionWithoutServerJargon() {
        let publicCopy = [
            PrivacySettingsCopy.encryptionIntro,
            PrivacySettingsCopy.browserHistoryEncryptionFooter
        ].joined(separator: " ")

        XCTAssertTrue(publicCopy.contains("encrypted on this Mac"))
        XCTAssertTrue(publicCopy.contains("time, sender, and source name"))
        XCTAssertTrue(publicCopy.contains("Search quality may drop"))
        XCTAssertFalse(publicCopy.lowercased().contains("server"))
        XCTAssertFalse(publicCopy.lowercased().contains("ciphertext"))
        XCTAssertFalse(publicCopy.lowercased().contains("metadata"))
        XCTAssertFalse(publicCopy.lowercased().contains("comparatively low"))
    }

    func testDevicesSettingsCopyDoesNotExposeServerLanguage() {
        let publicCopy = [
            DevicesSettingsCopy.footer,
            DevicesSettingsCopy.revokeConfirmation
        ].joined(separator: " ")

        XCTAssertTrue(publicCopy.contains("Re-pair"))
        XCTAssertTrue(publicCopy.contains("Data already synced to Maraithon is kept."))
        XCTAssertFalse(publicCopy.lowercased().contains("server"))
        XCTAssertFalse(publicCopy.lowercased().contains("bearer"))
        XCTAssertFalse(publicCopy.lowercased().contains("token"))
    }

    func testRecallCopyUsesReadableFallbackTitlesAndSources() {
        let message = RecallResult(
            source: "local_messages",
            id: "m1",
            title: "   ",
            snippet: "Can you send the agenda?",
            timestamp: nil,
            score: 0.9
        )
        let calendar = RecallResult(
            source: "local_calendar",
            id: "c1",
            title: nil,
            snippet: nil,
            timestamp: nil,
            score: 0.8
        )
        let unknown = RecallResult(
            source: "local_slack_messages",
            id: "s1",
            title: nil,
            snippet: nil,
            timestamp: nil,
            score: 0.7
        )

        XCTAssertEqual(RecallCopy.resultTitle(for: message), "Message")
        XCTAssertEqual(RecallCopy.resultTitle(for: calendar), "Calendar event")
        XCTAssertEqual(RecallCopy.resultTitle(for: unknown), "Search result")
        XCTAssertEqual(RecallCopy.sourceLabel(for: unknown.source), "Slack Messages")
        XCTAssertFalse(RecallCopy.sourceLabel(for: unknown.source).contains("_"))
        XCTAssertFalse(RecallCopy.resultTitle(for: message).contains("Untitled"))
    }

    func testRecallErrorCopyUsesSearchLanguage() {
        let copy = RecallCopy.searchError(MaraithonClientError.serverError(status: 503))

        XCTAssertEqual(copy, "Search could not finish. Maraithon is temporarily unavailable. Retry in a moment.")
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("Recall failed"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("serverError"))
    }

    @MainActor
    func testCompanionMenuBarCopyReflectsSignedInSourceState() {
        let account = DeviceAuth.Account(email: "kent@example.com", deviceName: "Kent's Mac")
        let signedIn = DeviceAuth.State.signedIn(account: account)

        XCTAssertEqual(
            CompanionMenuBarCopy.accessibilityLabel(
                isPaused: false,
                deviceAuthState: signedIn,
                sourceStates: [.connected]
            ),
            "Maraithon — up to date"
        )
        XCTAssertEqual(
            CompanionMenuBarCopy.accessibilityLabel(
                isPaused: false,
                deviceAuthState: signedIn,
                sourceStates: [.syncing]
            ),
            "Maraithon — syncing"
        )
        XCTAssertEqual(
            CompanionMenuBarCopy.accessibilityLabel(
                isPaused: false,
                deviceAuthState: signedIn,
                sourceStates: [.error(reason: "serverError(status: 503)")]
            ),
            "Maraithon — sync needs attention"
        )
        XCTAssertEqual(
            CompanionMenuBarCopy.accessibilityLabel(
                isPaused: false,
                deviceAuthState: signedIn,
                sourceStates: []
            ),
            "Maraithon — waiting to sync"
        )
    }

    @MainActor
    func testCompanionMenuBarCopyPrioritizesPausedAndAuthStates() {
        let account = DeviceAuth.Account(email: "kent@example.com", deviceName: "Kent's Mac")

        XCTAssertEqual(
            CompanionMenuBarCopy.accessibilityLabel(
                isPaused: true,
                deviceAuthState: .signedIn(account: account),
                sourceStates: [.syncing]
            ),
            "Maraithon — sync paused"
        )
        XCTAssertEqual(
            CompanionMenuBarCopy.accessibilityLabel(
                isPaused: false,
                deviceAuthState: .signedOut,
                sourceStates: [.connected]
            ),
            "Maraithon — not connected"
        )
        XCTAssertEqual(
            CompanionMenuBarCopy.symbol(
                isPaused: false,
                deviceAuthState: .signedIn(account: account),
                sourceStates: [.error(reason: "serverError(status: 503)")]
            ),
            "exclamationmark.octagon.fill"
        )
    }

    @MainActor
    func testBackfillWindowOptionsAllHaveTitles() {
        for window in BackfillSetupView.Window.allCases {
            XCTAssertFalse(window.title.isEmpty, "Window \(window) needs a title")
        }
    }

    @MainActor
    func testBackfillChoiceLogPayloadIsStable() {
        // Log payload must be stable for the analytics surface — the
        // string keys here are part of the observable contract.
        XCTAssertEqual(
            BackfillSetupView.Choice.last(days: 30).logPayload["choice"],
            "last_30_days"
        )
        XCTAssertEqual(
            BackfillSetupView.Choice.last(days: 90).logPayload["choice"],
            "last_90_days"
        )
        XCTAssertEqual(
            BackfillSetupView.Choice.fromDate(Date()).logPayload["choice"],
            "custom_date"
        )
        XCTAssertEqual(
            BackfillSetupView.Choice.fresh.logPayload["choice"],
            "fresh"
        )
    }

    @MainActor
    func testStatCardRendersWithoutCrashing() {
        // Constructing the view exercises the body in headless build.
        _ = StatCard(title: "Today", value: "47", trend: .up("+12"))
    }

    @MainActor
    func testDiagnosticsSummaryUsesDailyAcceptedTotals() {
        let messages = SourceStatusPublisher(state: .connected)
        let notes = SourceStatusPublisher(state: .connected)
        let now = Date()

        messages.recordSync(at: now, accepted: 12, duplicate: 0)
        messages.recordSync(at: now, accepted: 5, duplicate: 0)
        notes.recordSync(at: now, accepted: 7, duplicate: 0)

        XCTAssertEqual(
            DiagnosticsSummaryMetrics.eventsSyncedToday([messages, notes, nil]),
            24
        )
        XCTAssertNotEqual(
            DiagnosticsSummaryMetrics.eventsSyncedToday([messages, notes]),
            messages.lastBatchAccepted + notes.lastBatchAccepted
        )
    }
}
