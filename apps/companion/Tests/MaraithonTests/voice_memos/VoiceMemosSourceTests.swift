import XCTest
@testable import Maraithon

final class VoiceMemosSourceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-memos-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("CloudRecordings.db")
        try VoiceMemosFixture.build(at: dbURL)

        defaultsSuiteName = "com.maraithon.companion.voice_memos.tests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testSyncNowPushesPayloadsAndAdvancesCursor() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        XCTAssertEqual(batches.count, 1)
        let batch = batches[0]
        XCTAssertEqual(batch.deviceId, env.deviceId)
        // Two of the three fixture rows have audio on disk; the third
        // (missing .m4a) is dropped before push.
        XCTAssertEqual(batch.payloads.count, 2)
        XCTAssertEqual(Set(batch.payloads.map(\.guid)), Set([
            "VM-UUID-0001", "VM-UUID-0002"
        ]))
        XCTAssertEqual(VoiceMemosCursor(defaults: defaultsSuite).lastSyncedRowID, 2)
    }

    @MainActor
    func testCustomLabelFallsBackToDerivedTitle() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let labelled = batches[0].payloads.first { $0.guid == "VM-UUID-0001" }
        XCTAssertEqual(labelled?.title, "Team standup")

        let derived = batches[0].payloads.first { $0.guid == "VM-UUID-0002" }
        XCTAssertNotNil(derived)
        XCTAssertTrue(
            derived?.title?.hasPrefix("Voice Memo · ") ?? false,
            "Unlabelled recording should get a derived title, got: \(String(describing: derived?.title))"
        )
    }

    @MainActor
    func testLocalIDShapeMatchesSpec() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        let batches = await env.collector.snapshot()
        let one = batches[0].payloads.first { $0.guid == "VM-UUID-0001" }
        XCTAssertEqual(one?.localId, "p:1")
        let two = batches[0].payloads.first { $0.guid == "VM-UUID-0002" }
        XCTAssertEqual(two?.localId, "p:2")
    }

    @MainActor
    func testFileSizeFromDiskIsIncluded() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        let batches = await env.collector.snapshot()
        let one = batches[0].payloads.first { $0.guid == "VM-UUID-0001" }
        XCTAssertEqual(one?.fileSizeBytes, 482_948)
    }

    @MainActor
    func testRepeatedSyncDoesNotResendUnchangedRows() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        try await env.source.syncNow()
        let batches = await env.collector.snapshot()
        // Second sync should find nothing new → outbox not called again.
        XCTAssertEqual(batches.count, 1)
    }

    @MainActor
    func testAppendedRowOnNextSyncOnlyIncludesNewRow() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        try VoiceMemosFixture.appendRow(at: dbURL, VoiceMemosFixture.Row(
            pk: 10,
            uniqueID: "VM-LATER",
            customLabel: nil,
            dateSeconds: 779_600_000,
            durationSeconds: 5,
            relativePath: "later.m4a",
            fileBytes: 1024
        ))
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[1].payloads.count, 1)
        XCTAssertEqual(batches[1].payloads.first?.guid, "VM-LATER")
        XCTAssertEqual(VoiceMemosCursor(defaults: defaultsSuite).lastSyncedRowID, 10)
    }

    @MainActor
    func testRestartResumesFromPersistedCursor() async throws {
        let first = makeEnvironment()
        try await first.source.syncNow()
        let cursor = VoiceMemosCursor(defaults: defaultsSuite).lastSyncedRowID
        XCTAssertGreaterThan(cursor, 0)

        try VoiceMemosFixture.appendRow(at: dbURL, VoiceMemosFixture.Row(
            pk: 99,
            uniqueID: "VM-AFTER-RESTART",
            customLabel: "Resume marker",
            dateSeconds: 779_700_000,
            durationSeconds: 1,
            relativePath: "after.m4a",
            fileBytes: 256
        ))

        let second = makeEnvironment()
        try await second.source.syncNow()
        let batches = await second.collector.snapshot()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].payloads.count, 1)
        XCTAssertEqual(batches[0].payloads.first?.guid, "VM-AFTER-RESTART")
    }

    @MainActor
    func testClearLocalStateResetsCursor() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        XCTAssertGreaterThan(VoiceMemosCursor(defaults: defaultsSuite).lastSyncedRowID, 0)
        env.source.clearLocalState()
        XCTAssertEqual(VoiceMemosCursor(defaults: defaultsSuite).lastSyncedRowID, 0)
    }

    @MainActor
    func testOutboxFailureLeavesCursorUnchanged() async throws {
        let env = makeEnvironment(failingOutbox: true)
        do {
            try await env.source.syncNow()
            XCTFail("Expected push failure")
        } catch {
            // expected
        }
        XCTAssertEqual(
            VoiceMemosCursor(defaults: defaultsSuite).lastSyncedRowID,
            0,
            "Cursor must not advance on failed push"
        )
        if case .error = env.source.statusPublisher.displayedState() {
            // expected
        } else {
            XCTFail("failed sync should render red, got \(env.source.statusPublisher.displayedState())")
        }
    }

    @MainActor
    func testAuthorizationDeniedDatabaseOpenMapsToFullDiskAccessReason() {
        let error = VoiceMemosDatabase.DatabaseError.openFailed(
            code: 23,
            message: "authorization denied"
        )

        XCTAssertEqual(
            VoiceMemosSource.accessIssueReason(for: error),
            "voice_memos_full_disk_access_required"
        )
    }

    @MainActor
    func testMisspelledAuthorizationDeniedMessageStillMapsToAccessReason() {
        let error = VoiceMemosDatabase.DatabaseError.prepareFailed(
            message: "autheloirzation denied"
        )

        XCTAssertEqual(
            VoiceMemosSource.accessIssueReason(for: error),
            "voice_memos_full_disk_access_required"
        )
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let source: VoiceMemosSource
        let collector: VoiceMemosBatchCollector
        let deviceId: UUID
    }

    @MainActor
    private func makeEnvironment(failingOutbox: Bool = false) -> Environment {
        let log = EventLog(capacity: 128)
        let collector = VoiceMemosBatchCollector()
        let deviceId = UUID()
        let cursor = VoiceMemosCursor(defaults: defaultsSuite)
        // Inject an "always unavailable" transcriber. The real
        // `VoiceMemosTranscriber()` ends up calling
        // `SFSpeechRecognizer.requestAuthorization`, which fatals when
        // the executable has no Info.plist `NSSpeechRecognitionUsageDescription`
        // — true for `swift test` runs. The pre-v1.5 mechanics this
        // file covers don't care what the transcriber emits, so an
        // off-switch keeps the suite hermetic.
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in nil },
            authorizationProbe: { .denied }
        )
        let source = VoiceMemosSource(
            databaseURL: dbURL,
            cursor: cursor,
            eventLog: log,
            deviceIdProvider: { deviceId },
            pollInterval: 3600,
            batchLimit: 200,
            transcriber: transcriber,
            outbox: { deviceId, payloads in
                if failingOutbox {
                    throw MaraithonClientError.serverError(status: 500)
                }
                await collector.append(deviceId: deviceId, payloads: payloads)
                return SyncOutcome(accepted: payloads.count, duplicate: 0)
            }
        )
        return Environment(source: source, collector: collector, deviceId: deviceId)
    }
}

/// Thread-safe accumulator for batches the source hands to its outbox.
/// The outbox closure is `@Sendable`, so we can't capture a mutable array
/// directly — the actor gives us a safe landing pad. Mirrors
/// `BatchCollector` from `IMessageSourceTests` but typed for voice memos.
actor VoiceMemosBatchCollector {
    struct Batch: Equatable {
        let deviceId: UUID
        let payloads: [VoiceMemoPayload]
    }

    private var batches: [Batch] = []

    func append(deviceId: UUID, payloads: [VoiceMemoPayload]) {
        batches.append(Batch(deviceId: deviceId, payloads: payloads))
    }

    func snapshot() -> [Batch] {
        batches
    }
}
