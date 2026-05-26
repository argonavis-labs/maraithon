import XCTest
@testable import Maraithon

@MainActor
final class SyncEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-engine-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    nonisolated private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func makeAuth(_ keychain: KeychainStore = InMemoryKeychain(initial: "tok")) -> DeviceAuth {
        let suite = "engine-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DeviceAuth(
            eventLog: EventLog(capacity: 16),
            keychain: keychain,
            defaults: defaults,
            clientFactory: { _ in MaraithonClient(tokenProvider: { nil }, transport: { _ in (Data(), Self.http(200)) }) },
            urlOpener: { _ in }
        )
    }

    private func makeEnvelope(_ id: String) -> SyncEnvelope {
        SyncEnvelope(
            source: "imessage",
            localId: id,
            guid: "g\(id)",
            payload: ["text": AnyCodable("hi")]
        )
    }

    func testPushSuccessReportsAccepted() async throws {
        let log = EventLog(capacity: 64)
        let auth = makeAuth()
        let resp = try JSONEncoder().encode(IngestResponse(accepted: 5, duplicate: 1))
        let client = MaraithonClient(
            tokenProvider: { "tok" },
            transport: { _ in (resp, Self.http(200)) }
        )
        let engine = SyncEngine(
            eventLog: log,
            deviceAuth: auth,
            client: client,
            queue: SyncQueue(storageURL: tempDir.appendingPathComponent("q.json")),
            backoff: Backoff(initial: 0.001, multiplier: 2, cap: 0.01, maxAttempts: 3, jitter: 0)
        )

        let outcome = try await engine.push([makeEnvelope("1"), makeEnvelope("2")])
        XCTAssertEqual(outcome.accepted, 5)
        XCTAssertEqual(outcome.duplicate, 1)
        XCTAssertEqual(engine.health, .idle)
        XCTAssertEqual(engine.consecutiveFailures, 0)
    }

    func testRetriesOnTransientFailure() async throws {
        let counter = CallCounter()
        let goodBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let client = MaraithonClient(
            tokenProvider: { "tok" },
            transport: { _ in
                let n = await counter.increment()
                if n < 3 {
                    return (Data(), Self.http(500))
                } else {
                    return (goodBody, Self.http(200))
                }
            }
        )
        let engine = SyncEngine(
            eventLog: EventLog(capacity: 64),
            deviceAuth: makeAuth(),
            client: client,
            queue: SyncQueue(storageURL: tempDir.appendingPathComponent("q.json")),
            backoff: Backoff(initial: 0.001, multiplier: 1.5, cap: 0.01, maxAttempts: 5, jitter: 0)
        )

        let outcome = try await engine.push([makeEnvelope("1")])
        XCTAssertEqual(outcome.accepted, 1)
        let calls = await counter.value
        XCTAssertEqual(calls, 3)
    }

    func testThreeConsecutiveFailuresSurfaceNeedsAttention() async {
        let client = MaraithonClient(
            tokenProvider: { "tok" },
            transport: { _ in (Data(), Self.http(500)) }
        )
        let engine = SyncEngine(
            eventLog: EventLog(capacity: 64),
            deviceAuth: makeAuth(),
            client: client,
            queue: SyncQueue(storageURL: tempDir.appendingPathComponent("q.json")),
            backoff: Backoff(initial: 0.001, multiplier: 1, cap: 0.001, maxAttempts: 2, jitter: 0)
        )

        for _ in 0..<3 {
            _ = try? await engine.push([makeEnvelope("1")])
        }
        XCTAssertEqual(engine.health, .needsAttention(reason: "Connection issue"))
        XCTAssertEqual(engine.consecutiveFailures, 3)
    }

    func testUnauthorizedPropagatesWithoutRetry() async {
        let counter = CallCounter()
        let client = MaraithonClient(
            tokenProvider: { "tok" },
            transport: { _ in
                _ = await counter.increment()
                return (Data(), Self.http(401))
            }
        )
        let engine = SyncEngine(
            eventLog: EventLog(capacity: 64),
            deviceAuth: makeAuth(),
            client: client,
            queue: SyncQueue(storageURL: tempDir.appendingPathComponent("q.json")),
            backoff: Backoff(initial: 0.001, multiplier: 1, cap: 0.001, maxAttempts: 5, jitter: 0)
        )

        do {
            _ = try await engine.push([makeEnvelope("1")])
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            let n = await counter.value
            XCTAssertEqual(n, 1)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testDrainFlushesQueueAndAcknowledges() async throws {
        let body = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let calls = CallCounter()
        let client = MaraithonClient(
            tokenProvider: { "tok" },
            transport: { _ in
                _ = await calls.increment()
                return (body, Self.http(200))
            }
        )
        let queueURL = tempDir.appendingPathComponent("q.json")
        let queue = SyncQueue(storageURL: queueURL)
        let engine = SyncEngine(
            eventLog: EventLog(capacity: 64),
            deviceAuth: makeAuth(),
            client: client,
            queue: queue,
            backoff: Backoff(initial: 0.001, multiplier: 1, cap: 0.001, maxAttempts: 2, jitter: 0),
            batchSize: 2
        )

        try await engine.enqueue([
            makeEnvelope("1"), makeEnvelope("2"), makeEnvelope("3")
        ])
        try await engine.drain()
        let remaining = try await queue.count()
        XCTAssertEqual(remaining, 0)
        let httpCalls = await calls.value
        // 2 batches of size <= 2
        XCTAssertEqual(httpCalls, 2)
    }

    func testBackoffSchedule() {
        let b = Backoff(initial: 1, multiplier: 2, cap: 300, maxAttempts: 20, jitter: 0)
        XCTAssertEqual(b.delay(for: 1), 1)
        XCTAssertEqual(b.delay(for: 2), 2)
        XCTAssertEqual(b.delay(for: 3), 4)
        XCTAssertEqual(b.delay(for: 4), 8)
        XCTAssertEqual(b.delay(for: 10), 300)  // capped
        XCTAssertEqual(b.delay(for: 20), 300)  // still capped
    }

    func testBackoffJitterStaysInRange() {
        let b = Backoff(initial: 1, multiplier: 2, cap: 10, maxAttempts: 5, jitter: 0.2, randomSource: { 1.0 })
        let d = b.delay(for: 2)  // base 2 + 20% = 2.4
        XCTAssertEqual(d, 2.4, accuracy: 1e-9)

        let b2 = Backoff(initial: 1, multiplier: 2, cap: 10, maxAttempts: 5, jitter: 0.2, randomSource: { 0.0 })
        let d2 = b2.delay(for: 2)  // base 2 - 20% = 1.6
        XCTAssertEqual(d2, 1.6, accuracy: 1e-9)
    }
}

/// Concurrency-safe counter for assertions on retry call counts.
actor CallCounter {
    private(set) var value: Int = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
