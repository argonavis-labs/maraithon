import EventKit
import XCTest
@testable import Maraithon

final class RemindersSourceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "com.maraithon.companion.reminders-source-tests.\(UUID().uuidString)"
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
        let snap = RemindersReader.Snapshot(
            guid: "g1",
            title: "Pay rent",
            notes: "by Friday",
            listName: "Home",
            listColor: "#00FF00",
            priority: 1,
            dueAt: t,
            completedAt: nil,
            isCompleted: false,
            hasAlarm: true,
            urlAttachment: "https://example.com",
            createdAt: t,
            modifiedAt: t.addingTimeInterval(60)
        )
        let payload = RemindersSource.payload(from: snap)
        XCTAssertEqual(payload.guid, "g1")
        XCTAssertEqual(payload.localId, "r:g1")
        XCTAssertEqual(payload.title, "Pay rent")
        XCTAssertEqual(payload.notes, "by Friday")
        XCTAssertEqual(payload.listName, "Home")
        XCTAssertEqual(payload.listColor, "#00FF00")
        XCTAssertEqual(payload.priority, 1)
        XCTAssertEqual(payload.dueAt, t)
        XCTAssertNil(payload.completedAt)
        XCTAssertFalse(payload.isCompleted)
        XCTAssertTrue(payload.hasAlarm)
        XCTAssertEqual(payload.urlAttachment, "https://example.com")
        XCTAssertEqual(payload.modifiedAt, t.addingTimeInterval(60))
    }

    func testPayloadPassesPriorityZeroThrough() {
        let snap = RemindersReader.Snapshot(
            guid: "g",
            title: nil,
            notes: nil,
            listName: nil,
            listColor: nil,
            priority: 0,
            dueAt: nil,
            completedAt: nil,
            isCompleted: false,
            hasAlarm: false,
            urlAttachment: nil,
            createdAt: nil,
            modifiedAt: nil
        )
        XCTAssertEqual(RemindersSource.payload(from: snap).priority, 0)
    }

    // MARK: - Cycle behaviour

    @MainActor
    func testRunCyclePushesAllNewReminders() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = ReminderSnapshotStore(snapshots: [
            stub("a", modifiedAt: t),
            stub("b", modifiedAt: t.addingTimeInterval(60))
        ])
        let env = makeEnvironment(store: store)

        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "one POST issued")
        XCTAssertEqual(posted[0].count, 2)
        XCTAssertEqual(Set(posted[0].map(\.guid)), ["a", "b"])
    }

    @MainActor
    func testRunCycleSkipsUnchangedReminders() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = ReminderSnapshotStore(snapshots: [stub("a", modifiedAt: t)])
        let env = makeEnvironment(store: store)

        try await env.source.runCycle()
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "no second POST when nothing changed")
    }

    @MainActor
    func testRunCycleRepostsWhenModificationAdvances() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = ReminderSnapshotStore(snapshots: [stub("a", modifiedAt: t)])
        let env = makeEnvironment(store: store)

        try await env.source.runCycle()

        await store.set([stub("a", modifiedAt: t.addingTimeInterval(120), isCompleted: true)])
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[1].count, 1)
        XCTAssertEqual(posted[1][0].guid, "a")
        XCTAssertTrue(posted[1][0].isCompleted,
                      "completion flip should propagate on the re-push")
    }

    @MainActor
    func testCursorDoesNotAdvanceOnPushFailure() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = ReminderSnapshotStore(snapshots: [stub("a", modifiedAt: t)])
        let env = makeEnvironment(
            store: store,
            outboxFailure: NSError(domain: "test", code: 500)
        )

        do {
            try await env.source.runCycle()
            XCTFail("expected push failure to propagate")
        } catch {
            // expected
        }

        let cursor = RemindersCursor(defaults: defaults)
        XCTAssertEqual(cursor.trackedCount, 0,
                       "cursor must stay empty when the push failed")
    }

    @MainActor
    func testClearLocalStateResetsCursor() async throws {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = ReminderSnapshotStore(snapshots: [stub("a", modifiedAt: t)])
        let env = makeEnvironment(store: store)
        try await env.source.runCycle()

        XCTAssertEqual(RemindersCursor(defaults: defaults).trackedCount, 1)
        env.source.clearLocalState()
        XCTAssertEqual(RemindersCursor(defaults: defaults).trackedCount, 0)
    }

    @MainActor
    func testNotAuthorizedYieldsNeedsAttentionAndNoPost() async throws {
        let store = ReminderSnapshotStore(snapshots: [stub("a", modifiedAt: Date())])
        let env = makeEnvironment(store: store, authState: .denied)
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
        let snaps: [RemindersReader.Snapshot] = (0..<10).map { i in
            stub("g-\(i)", modifiedAt: t.addingTimeInterval(Double(i)))
        }
        let store = ReminderSnapshotStore(snapshots: snaps)
        let env = makeEnvironment(store: store, batchLimit: 4)
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].count, 4)
    }

    @MainActor
    func testRunCyclePushesReminderWithMissingModifiedAt() async throws {
        // EventKit can legitimately give us a reminder without a
        // lastModifiedDate (rare, but possible). We still push it on
        // every cycle because there's no way to dedupe by mtime —
        // the server's upsert keeps it idempotent.
        let store = ReminderSnapshotStore(snapshots: [stub("a", modifiedAt: nil)])
        let env = makeEnvironment(store: store)
        try await env.source.runCycle()
        try await env.source.runCycle()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 2,
                       "rows without a modifiedAt re-push every cycle")
    }

    // MARK: - Helpers

    private func stub(
        _ guid: String,
        modifiedAt: Date?,
        isCompleted: Bool = false
    ) -> RemindersReader.Snapshot {
        RemindersReader.Snapshot(
            guid: guid,
            title: "Title \(guid)",
            notes: nil,
            listName: "Personal",
            listColor: nil,
            priority: 0,
            dueAt: nil,
            completedAt: isCompleted ? modifiedAt : nil,
            isCompleted: isCompleted,
            hasAlarm: false,
            urlAttachment: nil,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt
        )
    }

    @MainActor
    private struct Environment {
        let source: RemindersSource
        let collector: ReminderBatchCollector
    }

    @MainActor
    private func makeEnvironment(
        store: ReminderSnapshotStore,
        outboxFailure: Error? = nil,
        batchLimit: Int = 200,
        authState: RemindersReader.AuthorizationOutcome = .authorized
    ) -> Environment {
        let log = EventLog(capacity: 128)
        let collector = ReminderBatchCollector()
        let cursor = RemindersCursor(defaults: defaults)
        let deviceId = UUID()

        let outbox: RemindersSource.Outbox = { _, payloads in
            if let outboxFailure {
                throw outboxFailure
            }
            await collector.append(payloads)
            return SyncOutcome(accepted: payloads.count, duplicate: 0)
        }

        let probeStatus = mapAuth(authState)
        let reader = RemindersReader(
            authorizationProbe: { probeStatus },
            fetchOverride: { await store.current() }
        )
        let source = RemindersSource(
            reader: reader,
            cursor: cursor,
            eventLog: log,
            deviceIdProvider: { deviceId },
            pollInterval: 3600,
            batchLimit: batchLimit,
            outbox: outbox
        )
        return Environment(source: source, collector: collector)
    }

    private func mapAuth(_ outcome: RemindersReader.AuthorizationOutcome) -> EKAuthorizationStatus {
        switch outcome {
        case .authorized: return .fullAccess
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        }
    }
}

/// Mutable snapshot store backing the test reader, so a single test
/// can simulate Reminders.app changes between cycles.
actor ReminderSnapshotStore {
    private var snapshots: [RemindersReader.Snapshot]

    init(snapshots: [RemindersReader.Snapshot]) {
        self.snapshots = snapshots
    }

    func set(_ snapshots: [RemindersReader.Snapshot]) {
        self.snapshots = snapshots
    }

    func current() -> [RemindersReader.Snapshot] {
        snapshots
    }
}

/// Batches captured by the test outbox. One element per push call.
actor ReminderBatchCollector {
    private var batches: [[ReminderPayload]] = []
    func append(_ batch: [ReminderPayload]) { batches.append(batch) }
    func snapshot() -> [[ReminderPayload]] { batches }
}
