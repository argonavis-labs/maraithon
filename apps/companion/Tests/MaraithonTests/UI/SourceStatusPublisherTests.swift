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
        XCTAssertTrue(publisher.recentBatches.isEmpty)
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
}
