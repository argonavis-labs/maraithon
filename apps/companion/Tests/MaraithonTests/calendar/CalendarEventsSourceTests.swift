import XCTest
@testable import Maraithon

final class CalendarEventsSourceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "com.maraithon.companion.calendar-source-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Payload mapping

    func testPayloadFromSnapshotProjectsAllFields() {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let snap = CalendarEventReader.Snapshot(
            guid: "g1@2026",
            masterIdentifier: "MASTER",
            calendarName: "Work",
            calendarColor: "#00FF00",
            title: "Launch review",
            notes: "agenda",
            location: "Boardroom",
            startAt: t,
            endAt: t.addingTimeInterval(3600),
            isAllDay: false,
            isRecurring: true,
            organizerEmail: "host@example.com",
            attendeesCount: 2,
            attendeeEmails: ["a@example.com", "b@example.com"],
            createdAt: t,
            modifiedAt: t.addingTimeInterval(60)
        )
        let payload = CalendarEventsSource.payload(from: snap)
        XCTAssertEqual(payload.guid, "g1@2026")
        XCTAssertEqual(payload.localId, "cal:MASTER")
        XCTAssertEqual(payload.calendarName, "Work")
        XCTAssertEqual(payload.calendarColor, "#00FF00")
        XCTAssertEqual(payload.title, "Launch review")
        XCTAssertEqual(payload.notes, "agenda")
        XCTAssertEqual(payload.location, "Boardroom")
        XCTAssertEqual(payload.startAt, t)
        XCTAssertEqual(payload.endAt, t.addingTimeInterval(3600))
        XCTAssertFalse(payload.isAllDay)
        XCTAssertTrue(payload.isRecurring)
        XCTAssertEqual(payload.organizerEmail, "host@example.com")
        XCTAssertEqual(payload.attendeesCount, 2)
        XCTAssertEqual(payload.attendeeEmails, ["a@example.com", "b@example.com"])
        XCTAssertEqual(payload.modifiedAt, t.addingTimeInterval(60))
    }

    // MARK: - Cycle behaviour

    @MainActor
    func testRunCyclePushesAllNewEvents() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let snapshots = [
            stub("a", modifiedAt: t),
            stub("b", modifiedAt: t.addingTimeInterval(60))
        ]
        let env = makeEnvironment(snapshots: snapshots)

        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "one POST issued")
        XCTAssertEqual(posted[0].count, 2)
        XCTAssertEqual(Set(posted[0].map(\.guid)), ["a", "b"])
    }

    @MainActor
    func testRunCycleSkipsUnchangedEvents() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let env = makeEnvironment(snapshots: [stub("a", modifiedAt: t)])

        try await env.source.runCycle()
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "no second POST when nothing changed")
    }

    @MainActor
    func testRunCycleRepostsWhenModificationAdvances() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let snap1 = stub("a", modifiedAt: t, title: "Original")
        let snap2 = stub("a", modifiedAt: t.addingTimeInterval(120), title: "Rescheduled")

        let stubReader = CalendarStubReader(initial: [snap1])
        let env = makeEnvironment(stub: stubReader)
        try await env.source.runCycle()

        await stubReader.set([snap2])
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[1].count, 1)
        XCTAssertEqual(posted[1][0].guid, "a")
        XCTAssertEqual(posted[1][0].title, "Rescheduled")
    }

    @MainActor
    func testCursorDoesNotAdvanceOnPushFailure() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let env = makeEnvironment(
            snapshots: [stub("a", modifiedAt: t)],
            outboxFailure: NSError(domain: "test", code: 500)
        )

        do {
            try await env.source.runCycle()
            XCTFail("expected push failure to propagate")
        } catch {
            // expected
        }

        let cursor = CalendarCursor(defaults: defaults)
        XCTAssertEqual(cursor.trackedCount, 0,
                       "cursor must stay empty when the push failed")
    }

    @MainActor
    func testClearLocalStateResetsCursor() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let env = makeEnvironment(snapshots: [stub("a", modifiedAt: t)])
        try await env.source.runCycle()

        XCTAssertEqual(CalendarCursor(defaults: defaults).trackedCount, 1)
        env.source.clearLocalState()
        XCTAssertEqual(CalendarCursor(defaults: defaults).trackedCount, 0)
    }

    @MainActor
    func testNotAuthorizedYieldsNeedsAttentionAndNoPost() async throws {
        let env = makeEnvironment(
            snapshots: [stub("a", modifiedAt: Date())],
            authState: .denied
        )
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertTrue(posted.isEmpty)
        switch env.source.statusPublisher.state {
        case .needsAttention:
            break // expected
        default:
            XCTFail("expected needsAttention state, got \(env.source.statusPublisher.state)")
        }
    }

    @MainActor
    func testBatchLimitClampsPushedCount() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let snapshots: [CalendarEventReader.Snapshot] = (0..<10).map { i in
            stub("g-\(i)", modifiedAt: t.addingTimeInterval(Double(i)))
        }
        let env = makeEnvironment(snapshots: snapshots, batchLimit: 4)
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].count, 4)
    }

    @MainActor
    func testWindowMathPassesLookbackAndLookaheadToReader() async throws {
        let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stubReader = CalendarStubReader(initial: [])
        let env = makeEnvironment(
            stub: stubReader,
            lookbackDays: 10,
            lookaheadDays: 20,
            clock: { fixedNow }
        )
        try await env.source.runCycle()

        let captured = await stubReader.lastQuery
        let q = try XCTUnwrap(captured)
        XCTAssertEqual(q.start, fixedNow.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(q.end, fixedNow.addingTimeInterval(20 * 86_400))
    }

    // MARK: - Helpers

    private func stub(
        _ guid: String,
        modifiedAt: Date?,
        title: String = "Coffee"
    ) -> CalendarEventReader.Snapshot {
        CalendarEventReader.Snapshot(
            guid: guid,
            masterIdentifier: guid,
            calendarName: "Home",
            calendarColor: nil,
            title: title,
            notes: nil,
            location: nil,
            startAt: modifiedAt ?? Date(),
            endAt: (modifiedAt ?? Date()).addingTimeInterval(1800),
            isAllDay: false,
            isRecurring: false,
            organizerEmail: nil,
            attendeesCount: 0,
            attendeeEmails: [],
            createdAt: modifiedAt,
            modifiedAt: modifiedAt
        )
    }

    @MainActor
    private struct Environment {
        let source: CalendarEventsSource
        let collector: CalendarBatchCollector
    }

    @MainActor
    private func makeEnvironment(
        snapshots: [CalendarEventReader.Snapshot] = [],
        stub: CalendarStubReader? = nil,
        outboxFailure: Error? = nil,
        batchLimit: Int = 200,
        authState: CalendarEventReader.AuthorizationOutcome = .authorized,
        lookbackDays: TimeInterval = 90,
        lookaheadDays: TimeInterval = 180,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> Environment {
        let log = EventLog(capacity: 128)
        let collector = CalendarBatchCollector()
        let stubReader = stub ?? CalendarStubReader(initial: snapshots)
        let cursor = CalendarCursor(defaults: defaults)
        let deviceId = UUID()

        let outbox: CalendarEventsSource.Outbox = { _, payloads in
            if let outboxFailure {
                throw outboxFailure
            }
            await collector.append(payloads)
            return SyncOutcome(accepted: payloads.count, duplicate: 0)
        }

        let mappedAuth: EKAuthorizationStatusBridge = .from(authState)
        let liveReader = CalendarEventReader(
            authorizationProbe: { mappedAuth.rawStatus },
            fetchOverride: { start, end in
                await stubReader.fetch(start: start, end: end)
            }
        )
        let source = CalendarEventsSource(
            reader: liveReader,
            cursor: cursor,
            eventLog: log,
            deviceIdProvider: { deviceId },
            pollInterval: 3600,
            batchLimit: batchLimit,
            lookbackDays: lookbackDays,
            lookaheadDays: lookaheadDays,
            clock: clock,
            outbox: outbox
        )
        return Environment(source: source, collector: collector)
    }
}

/// Mutable snapshot store backing the stub reader so a single test can
/// simulate Calendar.app changes between cycles.
actor CalendarStubReader {
    private var snapshots: [CalendarEventReader.Snapshot]
    private(set) var lastQuery: (start: Date, end: Date)?

    init(initial: [CalendarEventReader.Snapshot]) {
        self.snapshots = initial
    }

    func set(_ snapshots: [CalendarEventReader.Snapshot]) {
        self.snapshots = snapshots
    }

    func fetch(start: Date, end: Date) -> [CalendarEventReader.Snapshot] {
        self.lastQuery = (start, end)
        return snapshots
    }
}

/// Bridges our `AuthorizationOutcome` cases back to `EKAuthorizationStatus`
/// so the test reader's `authorizationProbe` can hand the right value
/// to the production code without test files reaching into EventKit
/// directly.
import EventKit
struct EKAuthorizationStatusBridge: Sendable {
    let rawStatus: EKAuthorizationStatus

    static func from(_ outcome: CalendarEventReader.AuthorizationOutcome) -> EKAuthorizationStatusBridge {
        switch outcome {
        case .authorized: return .init(rawStatus: .authorized)
        case .denied: return .init(rawStatus: .denied)
        case .restricted: return .init(rawStatus: .restricted)
        case .notDetermined: return .init(rawStatus: .notDetermined)
        case .writeOnly: return .init(rawStatus: .writeOnly)
        }
    }
}

actor CalendarBatchCollector {
    private var batches: [[CalendarEventPayload]] = []
    func append(_ batch: [CalendarEventPayload]) { batches.append(batch) }
    func snapshot() -> [[CalendarEventPayload]] { batches }
}
