import XCTest
@testable import Maraithon

final class BrowserHistorySourceTests: XCTestCase {
    private var tempDir: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-source-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defaultsSuiteName = "com.maraithon.companion.browser-tests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Cursor

    func testCursorAdvancesPerBrowser() {
        let cursor = BrowserHistoryCursor(defaults: defaultsSuite)
        XCTAssertEqual(cursor.lastSyncedID(for: .chrome), 0)
        XCTAssertEqual(cursor.lastSyncedID(for: .safari), 0)

        cursor.advance(.chrome, to: 42)
        XCTAssertEqual(cursor.lastSyncedID(for: .chrome), 42)
        XCTAssertEqual(cursor.lastSyncedID(for: .safari), 0)

        cursor.advance(.safari, to: 7)
        XCTAssertEqual(cursor.lastSyncedID(for: .chrome), 42)
        XCTAssertEqual(cursor.lastSyncedID(for: .safari), 7)
    }

    func testCursorRefusesToMoveBackwards() {
        let cursor = BrowserHistoryCursor(defaults: defaultsSuite)
        cursor.advance(.chrome, to: 42)
        cursor.advance(.chrome, to: 10)
        XCTAssertEqual(cursor.lastSyncedID(for: .chrome), 42)
    }

    func testCursorResetClearsAllBrowsers() {
        let cursor = BrowserHistoryCursor(defaults: defaultsSuite)
        cursor.advance(.chrome, to: 5)
        cursor.advance(.safari, to: 9)
        cursor.reset()
        XCTAssertEqual(cursor.lastSyncedID(for: .chrome), 0)
        XCTAssertEqual(cursor.lastSyncedID(for: .safari), 0)
    }

    // MARK: - Source

    @MainActor
    func testSyncNowFansOutToInstalledBrowsersAndPosts() async throws {
        let chromeURL = tempDir.appendingPathComponent("ChromeHistory")
        try BrowserHistoryFixture.buildChromium(at: chromeURL)
        let safariURL = tempDir.appendingPathComponent("SafariHistory.db")
        try BrowserHistoryFixture.buildSafari(at: safariURL)

        let env = try makeEnvironment(chromeURL: chromeURL, safariURL: safariURL)
        try await env.source.syncNow()
        let posted = await env.collector.snapshot()

        // Two POSTs, one per browser with rows seeded.
        XCTAssertEqual(posted.count, 2)
        let allRows = posted.flatMap { $0.visits }
        let chromeRows = allRows.filter { $0.browser == "chrome" }
        let safariRows = allRows.filter { $0.browser == "safari" }
        XCTAssertEqual(chromeRows.count, 3)
        XCTAssertEqual(safariRows.count, 2)
    }

    @MainActor
    func testCursorAdvancesPerBrowserAfterSuccessfulPost() async throws {
        let chromeURL = tempDir.appendingPathComponent("ChromeHistory")
        try BrowserHistoryFixture.buildChromium(at: chromeURL)
        let safariURL = tempDir.appendingPathComponent("SafariHistory.db")
        try BrowserHistoryFixture.buildSafari(at: safariURL)

        let env = try makeEnvironment(chromeURL: chromeURL, safariURL: safariURL)
        try await env.source.syncNow()

        let cursor = BrowserHistoryCursor(defaults: defaultsSuite)
        XCTAssertGreaterThan(cursor.lastSyncedID(for: .chrome), 0)
        XCTAssertGreaterThan(cursor.lastSyncedID(for: .safari), 0)

        // Empty second cycle — both browsers say "no new rows", no POSTs.
        try await env.source.syncNow()
        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 2, "no extra POSTs when nothing new")
    }

    @MainActor
    func testNoBrowsersInstalledStillReturnsCleanly() async throws {
        let env = try makeEnvironment(chromeURL: nil, safariURL: nil)
        try await env.source.syncNow()
        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 0)
    }

    @MainActor
    func testClearLocalStateWipesAllCursors() async throws {
        let chromeURL = tempDir.appendingPathComponent("ChromeHistory")
        try BrowserHistoryFixture.buildChromium(at: chromeURL)

        let env = try makeEnvironment(chromeURL: chromeURL, safariURL: nil)
        try await env.source.syncNow()
        XCTAssertGreaterThan(
            BrowserHistoryCursor(defaults: defaultsSuite).lastSyncedID(for: .chrome),
            0
        )
        env.source.clearLocalState()
        XCTAssertEqual(
            BrowserHistoryCursor(defaults: defaultsSuite).lastSyncedID(for: .chrome),
            0
        )
    }

    @MainActor
    func testCursorAdvancesEvenWhenServerFiltersRows() async throws {
        // Server reports filtered=3 (matches all chromium rows) and
        // accepted=0; the source still needs to advance so we don't
        // re-read those rows next cycle. The exact filtered value is a
        // server choice — what matters here is that the cursor moves.
        let chromeURL = tempDir.appendingPathComponent("ChromeHistory")
        try BrowserHistoryFixture.buildChromium(at: chromeURL)

        let env = try makeEnvironment(
            chromeURL: chromeURL,
            safariURL: nil,
            responseAccepted: 0,
            responseFiltered: 3
        )
        try await env.source.syncNow()
        XCTAssertGreaterThan(
            BrowserHistoryCursor(defaults: defaultsSuite).lastSyncedID(for: .chrome),
            0
        )
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let source: BrowserHistorySource
        let collector: BrowserPostCollector
    }

    @MainActor
    private func makeEnvironment(
        chromeURL: URL?,
        safariURL: URL?,
        responseAccepted: Int = 3,
        responseFiltered: Int = 0
    ) throws -> Environment {
        let log = EventLog(capacity: 128)
        let collector = BrowserPostCollector()
        let baseURL = URL(string: "https://test.maraithon.invalid")!
        let deviceId = UUID()

        let stubTransport: MaraithonClient.Transport = { request in
            let bodyData = request.httpBody ?? Data()
            let plain: Data
            if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
                plain = (try? Gzip.decompress(bodyData)) ?? bodyData
            } else {
                plain = bodyData
            }
            if let batch = try? JSONDecoder().decode(BrowserHistoryIngestBatch.self, from: plain) {
                await collector.append(batch)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
                {"accepted":\(responseAccepted),"duplicate":0,"invalid":0,"filtered":\(responseFiltered)}
                """.data(using: .utf8) ?? Data()
            return (body, response)
        }

        let ingest = BrowserHistoryIngest(
            baseURL: baseURL,
            tokenProvider: { "test-token" },
            transport: stubTransport
        )

        let cursor = BrowserHistoryCursor(defaults: defaultsSuite)
        // Inject readers directly via a fake factory so tests don't
        // depend on the user's real history files.
        let factory: BrowserHistorySource.ReaderFactory = { browser in
            switch browser {
            case .chrome:
                guard let url = chromeURL else { return nil }
                return try? ChromiumHistoryReader(browser: .chrome, liveURL: url)
            case .safari:
                guard let url = safariURL else { return nil }
                return try? SafariHistoryReader(liveURL: url)
            case .arc, .brave:
                return nil
            }
        }

        let source = BrowserHistorySource(
            cursor: cursor,
            eventLog: log,
            ingest: ingest,
            deviceIdProvider: { deviceId },
            readerFactory: factory,
            pollInterval: 3600
        )
        return Environment(source: source, collector: collector)
    }
}

/// Thread-safe accumulator for decoded ingest batches.
actor BrowserPostCollector {
    private var batches: [BrowserHistoryIngestBatch] = []

    func append(_ batch: BrowserHistoryIngestBatch) {
        batches.append(batch)
    }

    func snapshot() -> [BrowserHistoryIngestBatch] {
        batches
    }
}
