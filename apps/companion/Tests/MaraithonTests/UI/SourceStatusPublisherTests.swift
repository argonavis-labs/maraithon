import XCTest
@testable import Maraithon

/// Covers the per-day accepted counter used by the sidebar to show
/// "n today" beside each source. The bucket rolls over the first time
/// `recordSync` fires on a calendar day other than the bucket's day.
@MainActor
final class SourceStatusPublisherTests: XCTestCase {
    func testAcceptedTodayStartsAtZero() {
        let publisher = SourceStatusPublisher(calendar: utcCalendar)
        XCTAssertEqual(publisher.acceptedToday, 0)
    }

    func testAcceptedTodayAccumulatesWithinASingleDay() {
        let publisher = SourceStatusPublisher(calendar: utcCalendar)
        let morning = date("2026-05-11T08:00:00Z")
        let afternoon = date("2026-05-11T15:30:00Z")

        publisher.recordSync(at: morning, accepted: 12, duplicate: 1)
        publisher.recordSync(at: afternoon, accepted: 5, duplicate: 0)

        XCTAssertEqual(publisher.acceptedToday, 17)
    }

    func testAcceptedTodayResetsOnDayRollover() {
        let publisher = SourceStatusPublisher(calendar: utcCalendar)
        let dayOne = date("2026-05-10T22:00:00Z")
        let dayTwo = date("2026-05-11T01:00:00Z")

        publisher.recordSync(at: dayOne, accepted: 9, duplicate: 0)
        XCTAssertEqual(publisher.acceptedToday, 9)

        publisher.recordSync(at: dayTwo, accepted: 4, duplicate: 0)
        XCTAssertEqual(publisher.acceptedToday, 4)
    }

    func testAcceptedTodayIgnoresDuplicateCount() {
        let publisher = SourceStatusPublisher(calendar: utcCalendar)
        publisher.recordSync(at: Date(), accepted: 3, duplicate: 99)
        XCTAssertEqual(publisher.acceptedToday, 3)
    }

    func testRecordSyncWithSomeFailuresCreatesWarningIssue() {
        let publisher = SourceStatusPublisher(state: .connected)

        publisher.recordSync(
            at: Date(),
            accepted: 10,
            duplicate: 0,
            failed: 2,
            issueSummary: "2 messages did not sync."
        )

        XCTAssertEqual(publisher.lastBatchFailed, 2)
        XCTAssertEqual(publisher.totalFailed, 2)
        XCTAssertEqual(publisher.activeIssue?.severity, .warning)
        XCTAssertEqual(
            publisher.displayedState(),
            .needsAttention(reason: "2 messages did not sync.")
        )
        XCTAssertNil(publisher.activeBlockingIssue)
    }

    func testRecordSyncWithTooManyFailuresCreatesErrorIssue() {
        let publisher = SourceStatusPublisher(state: .connected)

        publisher.recordSync(
            at: Date(),
            accepted: 1,
            duplicate: 0,
            failed: 1,
            issueSummary: "1 item did not sync."
        )

        XCTAssertEqual(publisher.activeIssue?.severity, .error)
        XCTAssertEqual(
            publisher.displayedState(),
            .error(reason: "1 item did not sync.")
        )
        XCTAssertEqual(publisher.activeBlockingIssue?.reason, "1 item did not sync.")
    }

    func testRecoverablePermissionFailuresDoNotBecomeGenericBlockingIssues() {
        for reason in [
            "calendar_not_authorized",
            "imessage_full_disk_access_required",
            "notes_full_disk_access_required",
            "reminders_not_authorized",
            "voice_memos_speech_not_authorized",
            "voice_memos_full_disk_access_required"
        ] {
            let publisher = SourceStatusPublisher(state: .connected)

            publisher.recordCycleFailure(at: Date(), reason: reason)

            XCTAssertEqual(
                publisher.displayedState(),
                .error(reason: reason)
            )
            XCTAssertNil(
                publisher.activeBlockingIssue,
                "\(reason) should render the focused permission unblock view"
            )
        }
    }

    func testDefaultFailureSummaryAvoidsServerRejectionLanguage() {
        let publisher = SourceStatusPublisher(state: .connected)

        publisher.recordSync(
            at: Date(),
            accepted: 0,
            duplicate: 0,
            failed: 2
        )

        XCTAssertEqual(publisher.activeIssue?.reason, "2 items did not sync.")
        XCTAssertFalse(publisher.activeIssue?.reason.lowercased().contains("server") ?? true)
        XCTAssertFalse(publisher.activeIssue?.reason.lowercased().contains("rejected") ?? true)
    }

    // MARK: recordHealthyCycle

    func testRecordHealthyCycleSetsLastSyncAtOnly() {
        let publisher = SourceStatusPublisher()
        let now = Date()

        publisher.recordHealthyCycle(at: now)

        XCTAssertEqual(publisher.lastSyncAt, now)
        XCTAssertEqual(publisher.acceptedToday, 0)
        XCTAssertEqual(publisher.totalAccepted, 0)
        XCTAssertEqual(publisher.lastBatchAccepted, 0)
        XCTAssertEqual(publisher.lastBatchDuplicate, 0)
        XCTAssertEqual(publisher.lastBatchFailed, 0)
        XCTAssertTrue(publisher.recentBatches.isEmpty)
    }

    func testRecordHealthyCycleClearsStaleLastCheckCountsButKeepsTotals() {
        let publisher = SourceStatusPublisher()
        let first = date("2026-05-11T08:00:00Z")
        let second = date("2026-05-11T08:05:00Z")

        publisher.recordSync(at: first, accepted: 4, duplicate: 2, failed: 1)
        publisher.recordHealthyCycle(at: second)

        XCTAssertEqual(publisher.lastSyncAt, second)
        XCTAssertEqual(publisher.lastBatchAccepted, 0)
        XCTAssertEqual(publisher.lastBatchDuplicate, 0)
        XCTAssertEqual(publisher.lastBatchFailed, 0)
        XCTAssertEqual(publisher.totalAccepted, 4)
        XCTAssertEqual(publisher.totalDuplicate, 2)
        XCTAssertEqual(publisher.totalFailed, 1)
        XCTAssertEqual(publisher.acceptedToday, 4)
        XCTAssertEqual(publisher.recentBatches.count, 1)
    }

    func testRecordHealthyCycleClearsTransportFailureButNotPartialIssue() {
        let publisher = SourceStatusPublisher(state: .connected)
        publisher.recordCycleFailure(at: Date(), reason: "network down")
        XCTAssertEqual(publisher.activeIssue?.severity, .error)

        publisher.recordHealthyCycle(at: Date())
        XCTAssertNil(publisher.activeIssue)

        publisher.recordSync(
            at: Date(),
            accepted: 5,
            duplicate: 0,
            failed: 1,
            issueSummary: "1 note did not sync."
        )
        publisher.recordHealthyCycle(at: Date())

        XCTAssertEqual(publisher.activeIssue?.severity, .warning)
    }

    func testPersistentPublisherRestoresLastCheckContext() {
        let defaults = makeDefaults()
        let now = Date()
        let publisher = SourceStatusPublisher(
            sourceID: "imessage",
            state: .connected,
            defaults: defaults
        )

        publisher.recordSync(
            at: now,
            accepted: 4,
            duplicate: 2,
            failed: 1,
            issueSummary: "1 message did not sync.",
            latencyMS: 42
        )

        let restored = SourceStatusPublisher(
            sourceID: "imessage",
            state: .connected,
            defaults: defaults
        )

        XCTAssertEqual(restored.lastSyncAt, now)
        XCTAssertEqual(restored.lastBatchAccepted, 4)
        XCTAssertEqual(restored.lastBatchDuplicate, 2)
        XCTAssertEqual(restored.lastBatchFailed, 1)
        XCTAssertEqual(restored.totalAccepted, 4)
        XCTAssertEqual(restored.totalDuplicate, 2)
        XCTAssertEqual(restored.totalFailed, 1)
        XCTAssertEqual(restored.acceptedToday, 4)
        XCTAssertEqual(restored.recentBatches.count, 1)
        XCTAssertEqual(restored.recentBatches.first?.latencyMS, 42)
        XCTAssertEqual(restored.activeIssue?.reason, "1 message did not sync.")
    }

    func testPersistentPublisherResetsStaleDailyCountOnRestore() {
        let defaults = makeDefaults()
        let twoDaysAgo = Date().addingTimeInterval(-172_800)
        let publisher = SourceStatusPublisher(
            sourceID: "notes",
            state: .connected,
            defaults: defaults
        )

        publisher.recordSync(at: twoDaysAgo, accepted: 8, duplicate: 0)

        let restored = SourceStatusPublisher(
            sourceID: "notes",
            state: .connected,
            defaults: defaults
        )

        XCTAssertEqual(restored.totalAccepted, 8)
        XCTAssertEqual(restored.acceptedToday, 0)
    }

    func testDisplayedStateKeepsBlockingPermissionIssuesRedEvenAfterPriorSync() {
        for reason in [
            "imessage_full_disk_access_required",
            "notes_full_disk_access_required",
            "voice_memos_full_disk_access_required"
        ] {
            let publisher = SourceStatusPublisher(state: .connected)
            publisher.recordHealthyCycle(at: Date())
            publisher.update(state: .needsAttention(reason: reason))

            XCTAssertEqual(
                publisher.displayedState(),
                .error(reason: reason)
            )
        }
    }

    func testPersistentPublisherRestoresBlockingPermissionUntilHealthyCycle() {
        let defaults = makeDefaults()
        let now = Date()
        let reason = "imessage_full_disk_access_required"
        let publisher = SourceStatusPublisher(
            sourceID: "imessage",
            state: .connected,
            defaults: defaults
        )

        publisher.recordHealthyCycle(at: now)
        publisher.update(state: .needsAttention(reason: reason))

        let restored = SourceStatusPublisher(
            sourceID: "imessage",
            state: .connected,
            defaults: defaults
        )

        XCTAssertEqual(restored.blockingPermissionReason, reason)
        XCTAssertNotNil(restored.blockingPermissionRecordedAt)
        XCTAssertEqual(restored.displayedState(), .error(reason: reason))
        XCTAssertEqual(restored.fullDiskAccessBlockReason, reason)

        // Source start-up is optimistic; it should not erase a durable
        // permission block until the app proves it can read the source.
        restored.update(state: .connected)
        XCTAssertEqual(restored.displayedState(), .error(reason: reason))

        restored.recordHealthyCycle(at: now.addingTimeInterval(60))
        restored.update(state: .connected)
        XCTAssertNil(restored.blockingPermissionReason)
        XCTAssertNil(restored.blockingPermissionRecordedAt)
        XCTAssertNil(restored.fullDiskAccessBlockReason)
        XCTAssertEqual(restored.displayedState(), .connected)
    }

    func testPersistentPublisherDropsLegacyFullDiskAccessBlockAfterSuccessfulHistory() throws {
        let defaults = makeDefaults()
        let reason = "imessage_full_disk_access_required"
        let publisher = SourceStatusPublisher(
            sourceID: "imessage",
            state: .connected,
            defaults: defaults
        )

        publisher.recordSync(at: Date(), accepted: 12, duplicate: 0)
        let key = "source_status.imessage"
        let data = try XCTUnwrap(defaults.data(forKey: key))
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        snapshot["blockingPermissionReason"] = reason
        snapshot.removeValue(forKey: "blockingPermissionRecordedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: snapshot)
        defaults.set(legacyData, forKey: key)

        let restored = SourceStatusPublisher(
            sourceID: "imessage",
            state: .connected,
            defaults: defaults
        )

        XCTAssertNil(restored.blockingPermissionReason)
        XCTAssertNil(restored.blockingPermissionRecordedAt)
        XCTAssertNil(restored.fullDiskAccessBlockReason)
        XCTAssertEqual(restored.displayedState(), .connected)
    }

    func testClearFullDiskAccessBlockRemovesPersistedPermissionState() {
        let reason = "imessage_full_disk_access_required"
        let publisher = SourceStatusPublisher(state: .connected)
        publisher.recordHealthyCycle(at: Date())
        publisher.update(state: .needsAttention(reason: reason))

        XCTAssertEqual(publisher.displayedState(), .error(reason: reason))
        XCTAssertEqual(publisher.fullDiskAccessBlockReason, reason)

        publisher.clearFullDiskAccessBlock()

        XCTAssertNil(publisher.blockingPermissionReason)
        XCTAssertNil(publisher.blockingPermissionRecordedAt)
        XCTAssertNil(publisher.fullDiskAccessBlockReason)
        XCTAssertEqual(publisher.state, .connected)
        XCTAssertEqual(publisher.displayedState(), .connected)
    }

    func testClearFullDiskAccessBlockRemovesLegacyPersistedIssue() {
        let reason = "imessage_full_disk_access_required"
        let publisher = SourceStatusPublisher(state: .connected)
        publisher.recordHealthyCycle(at: Date())
        publisher.recordCycleFailure(at: Date(), reason: reason)

        XCTAssertNil(publisher.blockingPermissionReason)
        XCTAssertEqual(publisher.displayedState(), .error(reason: reason))
        XCTAssertEqual(publisher.fullDiskAccessBlockReason, reason)

        publisher.clearFullDiskAccessBlock()

        XCTAssertNil(publisher.activeIssue)
        XCTAssertNil(publisher.fullDiskAccessBlockReason)
        XCTAssertEqual(publisher.displayedState(), .connected)
    }

    func testRestoredLegacyFullDiskAccessIssueClearsAfterGrantProbe() {
        let defaults = makeDefaults()
        let reason = "notes_full_disk_access_required"
        let publisher = SourceStatusPublisher(
            sourceID: "notes",
            state: .connected,
            defaults: defaults
        )
        publisher.recordHealthyCycle(at: Date())
        publisher.recordCycleFailure(at: Date(), reason: reason)

        let restored = SourceStatusPublisher(
            sourceID: "notes",
            state: .connected,
            defaults: defaults
        )

        XCTAssertNil(restored.blockingPermissionReason)
        XCTAssertEqual(restored.displayedState(), .error(reason: reason))

        restored.clearFullDiskAccessBlock()

        XCTAssertNil(restored.activeIssue)
        XCTAssertEqual(restored.displayedState(), .connected)
    }

    func testClearFullDiskAccessBlockDoesNotClearOtherPermissionFailures() {
        let reason = "calendar_not_authorized"
        let publisher = SourceStatusPublisher(state: .connected)
        publisher.update(state: .needsAttention(reason: reason))

        publisher.clearFullDiskAccessBlock()

        XCTAssertEqual(publisher.blockingPermissionReason, reason)
        XCTAssertEqual(publisher.displayedState(), .error(reason: reason))
        XCTAssertNil(publisher.fullDiskAccessBlockReason)
    }

    func testPersistentPublisherDoesNotRestoreNonBlockingAttention() {
        let defaults = makeDefaults()
        let reason = "voice_memos_speech_not_authorized"
        let publisher = SourceStatusPublisher(
            sourceID: "voice_memos",
            state: .connected,
            defaults: defaults
        )

        publisher.recordSync(at: Date(), accepted: 1, duplicate: 0)
        publisher.update(state: .needsAttention(reason: reason))

        let restored = SourceStatusPublisher(
            sourceID: "voice_memos",
            state: .connected,
            defaults: defaults
        )

        XCTAssertNil(restored.blockingPermissionReason)
        XCTAssertEqual(restored.displayedState(), .connected)
    }

    func testDisplayedStateKeepsPartialVoiceMemoTranscriptIssueYellowAfterSync() {
        let publisher = SourceStatusPublisher(state: .connected)
        publisher.recordSync(at: Date(), accepted: 1, duplicate: 0)
        publisher.update(state: .needsAttention(reason: "voice_memos_speech_not_authorized"))

        XCTAssertEqual(
            publisher.displayedState(),
            .needsAttention(reason: "voice_memos_speech_not_authorized")
        )
    }

    // MARK: SourceState.displayed(lastSyncAt:shippedBatch:)

    func testDisplayedDemotesConnectedWithoutAnySyncToDisconnected() {
        XCTAssertEqual(
            SourceState.connected.displayed(lastSyncAt: nil, shippedBatch: false),
            .disconnected
        )
    }

    func testDisplayedKeepsConnectedOnceAHeartbeatHasFired() {
        // A source that's fully caught up (cycle hits the empty path
        // every poll) is healthy. `lastSyncAt` set via
        // `recordHealthyCycle` is enough to light the dot green.
        XCTAssertEqual(
            SourceState.connected.displayed(lastSyncAt: Date(), shippedBatch: false),
            .connected
        )
    }

    func testDisplayedKeepsConnectedOnceARealBatchHasShipped() {
        XCTAssertEqual(
            SourceState.connected.displayed(lastSyncAt: Date(), shippedBatch: true),
            .connected
        )
    }

    func testDisplayedHoldsSyncingAsConnectedOnceABatchHasShipped() {
        // Once the source has shipped at least one batch this session,
        // the rotating "syncing" indicator becomes flashing noise on
        // every cycle (especially on aggressive backfill cadences).
        // Hold the steady green dot instead.
        XCTAssertEqual(
            SourceState.syncing.displayed(lastSyncAt: Date(), shippedBatch: true),
            .connected
        )
    }

    func testDisplayedPassesThroughNonConnectedStatesRegardlessOfHistory() {
        XCTAssertEqual(SourceState.syncing.displayed(lastSyncAt: nil, shippedBatch: false), .syncing)
        XCTAssertEqual(SourceState.paused.displayed(lastSyncAt: nil, shippedBatch: false), .paused)
        XCTAssertEqual(SourceState.disconnected.displayed(lastSyncAt: nil, shippedBatch: false), .disconnected)
        XCTAssertEqual(
            SourceState.needsAttention(reason: "x").displayed(lastSyncAt: nil, shippedBatch: false),
            .needsAttention(reason: "x")
        )
        XCTAssertEqual(
            SourceState.error(reason: "y").displayed(lastSyncAt: nil, shippedBatch: false),
            .error(reason: "y")
        )
    }

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let d = formatter.date(from: iso) else {
            XCTFail("bad ISO date \(iso)")
            return Date()
        }
        return d
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SourceStatusPublisherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
