import XCTest
@testable import Maraithon

/// Timing-focused coverage for `IMessageSource.start()`'s
/// `AsyncTimerSequence` poll loop. The correctness of a single cycle is
/// covered by `IMessageSourceTests`; this file proves that:
///
///   * `start()` fires multiple cycles when the cadence is short
///   * Low Power Mode stretches the effective cadence
///   * `pause()` cancels the timer cleanly
///
/// We drive the loop with `.continuous` clock and very short intervals
/// (≤50 ms) plus a brief sleep, rather than wiring an injectable mock
/// clock — the loop body is short enough that real-time scheduling
/// gives reliable counts within generous tolerances.
///
/// Cycles are counted by inspecting `EventLog`: every cycle attempt logs
/// exactly one of `imessage.cycle_empty`, `imessage.cycle_pushed`, or
/// `imessage.cycle_failed`. The fixture database has 5 messages, so the
/// first cycle logs `_pushed` and subsequent cycles log `_empty`.
final class IMessageTimerTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-timer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("chat.db")
        try IMessageFixture.build(at: dbURL)

        defaultsSuiteName = "com.maraithon.companion.timer-tests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testStartFiresMultipleCyclesWithinWindow() async throws {
        let env = makeEnvironment(
            pollInterval: 0.05,
            lowPowerProbe: { false }
        )

        env.source.start()
        // 300 ms window with a 50 ms cadence → ~6 ticks plus the priming
        // cycle; a generous lower bound rules out flake on busy CI.
        try await Task.sleep(nanoseconds: 300_000_000)
        env.source.pause()

        let count = cycleCount(env.log)
        XCTAssertGreaterThanOrEqual(
            count, 3,
            "expected several cycles within the test window, got \(count)"
        )
    }

    @MainActor
    func testStartFiresImmediatelyOnFirstTick() async throws {
        // Long cadence so we'd see zero cycles if `start()` waited for
        // the first interval. The priming cycle should bump the counter
        // basically immediately.
        let env = makeEnvironment(
            pollInterval: 60,
            lowPowerProbe: { false }
        )

        env.source.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        env.source.pause()

        let count = cycleCount(env.log)
        XCTAssertEqual(count, 1, "priming cycle should fire once at start")
    }

    @MainActor
    func testStartRechecksSourceAfterPersistedFullDiskAccessBlock() async throws {
        let env = makeEnvironment(
            pollInterval: 60,
            lowPowerProbe: { false },
            fullDiskAccessProbe: { false }
        )

        env.source.statusPublisher.recordHealthyCycle(at: Date())
        env.source.statusPublisher.update(state: .needsAttention(reason: "imessage_full_disk_access_required"))
        XCTAssertEqual(
            env.source.statusPublisher.displayedState(),
            .error(reason: "imessage_full_disk_access_required")
        )

        env.source.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(cycleCount(env.log), 1)
        XCTAssertNil(env.source.statusPublisher.fullDiskAccessBlockReason)
        XCTAssertEqual(env.source.statusPublisher.displayedState(), .connected)
        XCTAssertTrue(
            env.log.entries.contains {
                $0.message == "imessage.rechecking_previous_full_disk_access_block"
            }
        )
        env.source.pause()
    }

    @MainActor
    func testLowPowerModeStretchesCadence() async throws {
        // 50 ms base, 1 s in low-power mode. Inside a 300 ms window we
        // should see exactly the priming cycle — every subsequent tick
        // is gated until 1 s has elapsed.
        let env = makeEnvironment(
            pollInterval: 0.05,
            lowPowerPollInterval: 1.0,
            lowPowerProbe: { true }
        )

        env.source.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        env.source.pause()

        let count = cycleCount(env.log)
        XCTAssertEqual(
            count, 1,
            "low-power gate should keep cycles to the priming run; got \(count)"
        )

        // Cadence-change log entry should fire on the first probe.
        let cadenceLogs = env.log.entries.filter { $0.message == "imessage.cadence_changed" }
        XCTAssertEqual(cadenceLogs.count, 1)
        XCTAssertEqual(cadenceLogs.first?.payload["low_power"], "true")
    }

    @MainActor
    func testPauseStopsFurtherCycles() async throws {
        let env = makeEnvironment(
            pollInterval: 0.05,
            lowPowerProbe: { false }
        )

        env.source.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        env.source.pause()
        // Give any in-flight detached cycle a moment to drain — pause()
        // cancels the loop but a cycle already mid-flight will still log
        // its outcome. Snapshot only after the quiesce.
        try await Task.sleep(nanoseconds: 100_000_000)
        let countAtPause = cycleCount(env.log)

        try await Task.sleep(nanoseconds: 300_000_000)
        let countAfter = cycleCount(env.log)
        XCTAssertEqual(
            countAfter, countAtPause,
            "no cycles should fire after pause()"
        )
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let source: IMessageSource
        let log: EventLog
    }

    @MainActor
    private func makeEnvironment(
        pollInterval: TimeInterval,
        lowPowerPollInterval: TimeInterval? = nil,
        lowPowerProbe: @escaping @Sendable () -> Bool,
        fullDiskAccessProbe: @escaping @Sendable () -> Bool = { FullDiskAccessProbe.isGranted() }
    ) -> Environment {
        let log = EventLog(capacity: 256)
        let blocklist = Blocklist()
        let cursor = IMessageCursor(defaults: defaultsSuite)
        let stubTransport: MaraithonClient.Transport = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return ("{\"accepted\":0,\"duplicate\":0}".data(using: .utf8) ?? Data(), response)
        }
        let ingest = IMessageIngest(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: { "test-token" },
            transport: stubTransport
        )
        let deviceId = UUID()
        let source = IMessageSource(
            databaseURL: dbURL,
            cursor: cursor,
            blocklist: blocklist,
            eventLog: log,
            ingest: ingest,
            deviceIdProvider: { deviceId },
            pollInterval: pollInterval,
            lowPowerPollInterval: lowPowerPollInterval,
            batchLimit: 200,
            lowPowerProbe: lowPowerProbe,
            fullDiskAccessProbe: fullDiskAccessProbe
        )
        return Environment(source: source, log: log)
    }

    @MainActor
    private func cycleCount(_ log: EventLog) -> Int {
        let markers: Set<String> = [
            "imessage.cycle_empty",
            "imessage.cycle_pushed",
            "imessage.cycle_failed"
        ]
        return log.entries.filter { markers.contains($0.message) }.count
    }
}
