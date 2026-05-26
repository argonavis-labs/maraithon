import XCTest
@testable import Maraithon

final class IMessageSourceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("chat.db")
        try IMessageFixture.build(at: dbURL)

        defaultsSuiteName = "com.maraithon.companion.tests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testReadsFixtureMessagesWithDecodedBodies() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()

        let delivered = await env.delivered
        XCTAssertEqual(delivered.count, 1, "exactly one batch posted")
        let batch = delivered[0]

        // 5 fixture messages, 1 from blocked handle → 4 pushed.
        XCTAssertEqual(batch.messages.count, 4)
        let guids = batch.messages.map(\.guid)
        XCTAssertEqual(Set(guids), Set(["MSG-0001", "MSG-0002", "MSG-0003", "MSG-0005"]))

        let msg3 = batch.messages.first { $0.guid == "MSG-0003" }
        XCTAssertNotNil(msg3, "attributedBody-only message present")
        XCTAssertEqual(msg3?.text, "Headed to lunch — anyone?")
    }

    @MainActor
    func testGroupChatTaggedAsGroup() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()

        let delivered = await env.delivered
        let batch = delivered[0]
        let groupMsg = batch.messages.first { $0.guid == "MSG-0003" }
        XCTAssertEqual(groupMsg?.chatStyle, "group")
        XCTAssertEqual(groupMsg?.chatDisplayName, "Team Group")

        let solo = batch.messages.first { $0.guid == "MSG-0001" }
        XCTAssertEqual(solo?.chatStyle, "im")
    }

    @MainActor
    func testCursorAdvancesAcrossPolls() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        let firstCursor = IMessageCursor(defaults: defaultsSuite).lastSyncedRowID
        XCTAssertGreaterThan(firstCursor, 0)

        // No new rows → no new batch delivered.
        try await env.source.syncNow()
        let afterFirst = await env.delivered
        XCTAssertEqual(afterFirst.count, 1)

        // Append a new row, sync again, expect a second batch with only that row.
        try IMessageFixture.appendMessage(
            at: dbURL,
            IMessageFixture.Row(
                guid: "MSG-LATER",
                text: "Late arrival",
                attributedBody: nil,
                isFromMe: false,
                service: "iMessage",
                dateAppleNs: 779_500_100_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: 1,
                chatRowID: 1
            )
        )
        try await env.source.syncNow()
        let afterAppend = await env.delivered
        XCTAssertEqual(afterAppend.count, 2)
        XCTAssertEqual(afterAppend[1].messages.count, 1)
        XCTAssertEqual(afterAppend[1].messages.first?.guid, "MSG-LATER")
        XCTAssertGreaterThan(
            IMessageCursor(defaults: defaultsSuite).lastSyncedRowID,
            firstCursor
        )
    }

    @MainActor
    func testRestartResumesFromPersistedCursor() async throws {
        let firstEnv = makeEnvironment()
        try await firstEnv.source.syncNow()
        let cursorAfterFirst = IMessageCursor(defaults: defaultsSuite).lastSyncedRowID
        XCTAssertGreaterThan(cursorAfterFirst, 0)

        // Append a row, then "restart" by building a brand-new source
        // pointed at the same UserDefaults suite.
        try IMessageFixture.appendMessage(
            at: dbURL,
            IMessageFixture.Row(
                guid: "MSG-AFTER-RESTART",
                text: "After restart",
                attributedBody: nil,
                isFromMe: false,
                service: "iMessage",
                dateAppleNs: 779_500_200_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: 1,
                chatRowID: 1
            )
        )

        let secondEnv = makeEnvironment(reuseBlocklist: firstEnv.blocklist)
        try await secondEnv.source.syncNow()
        let delivered = await secondEnv.delivered
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].messages.count, 1)
        XCTAssertEqual(delivered[0].messages.first?.guid, "MSG-AFTER-RESTART")
    }

    @MainActor
    func testClearLocalStateResetsCursor() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        XCTAssertGreaterThan(IMessageCursor(defaults: defaultsSuite).lastSyncedRowID, 0)
        env.source.clearLocalState()
        XCTAssertEqual(IMessageCursor(defaults: defaultsSuite).lastSyncedRowID, 0)
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let source: IMessageSource
        let log: EventLog
        let blocklist: Blocklist
        let collector: BatchCollector
        var delivered: [IMessageIngestBatch] { get async { await collector.snapshot() } }
    }

    @MainActor
    private func makeEnvironment(reuseBlocklist: Blocklist? = nil) -> Environment {
        let log = EventLog(capacity: 128)
        let blocklist = reuseBlocklist ?? Blocklist()
        blocklist.add("blocked@example.com")
        let collector = BatchCollector()
        let cursor = IMessageCursor(defaults: defaultsSuite)

        let stubTransport: MaraithonClient.Transport = { request in
            let bodyData = request.httpBody ?? Data()
            let plain: Data
            if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
                plain = (try? Gzip.decompress(bodyData)) ?? bodyData
            } else {
                plain = bodyData
            }
            if let batch = try? JSONDecoder().decode(IMessageIngestBatch.self, from: plain) {
                await collector.append(batch)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let count = (try? JSONDecoder().decode(IMessageIngestBatch.self, from: plain))?.messages.count ?? 0
            let responseBody = "{\"accepted\":\(count),\"duplicate\":0}".data(using: .utf8) ?? Data()
            return (responseBody, response)
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
            pollInterval: 3600,  // long enough that the loop never re-enters during a test
            batchLimit: 200
        )
        return Environment(source: source, log: log, blocklist: blocklist, collector: collector)
    }
}

/// Thread-safe accumulator for decoded `IMessageIngestBatch` values
/// captured from the stub HTTP transport.
actor BatchCollector {
    private var batches: [IMessageIngestBatch] = []

    func append(_ batch: IMessageIngestBatch) {
        batches.append(batch)
    }

    func snapshot() -> [IMessageIngestBatch] {
        batches
    }
}
