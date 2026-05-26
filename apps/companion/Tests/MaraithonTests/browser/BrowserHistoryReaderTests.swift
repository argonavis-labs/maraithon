import XCTest
@testable import Maraithon

final class BrowserHistoryReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-reader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Chromium (Chrome, Arc, Brave share schema)

    func testChromeReaderReadsAllRowsFromZeroCursor() throws {
        let dbURL = tempDir.appendingPathComponent("History")
        try BrowserHistoryFixture.buildChromium(at: dbURL)

        let reader = try ChromiumHistoryReader(browser: .chrome, liveURL: dbURL)
        let rows = try reader.visits(after: 0, limit: 100)
        XCTAssertEqual(rows.count, 3)
        let byUrl = Dictionary(uniqueKeysWithValues: rows.map { ($0.url, $0) })

        let techmeme = byUrl["https://techmeme.com/article-1"]
        XCTAssertEqual(techmeme?.title, "Techmeme: AI roundup")
        XCTAssertEqual(techmeme?.host, "techmeme.com")
        XCTAssertEqual(techmeme?.browser, "chrome")
        XCTAssertEqual(techmeme?.visitCount, 3)
        XCTAssertEqual(techmeme?.isTypedUrl, false)
        XCTAssertTrue(techmeme?.guid.hasPrefix("chrome:") ?? false)
        // Timestamp should be a non-empty ISO-8601 string.
        XCTAssertNotNil(techmeme?.lastVisitedAt)
    }

    func testChromeReaderMarksTypedUrls() throws {
        let dbURL = tempDir.appendingPathComponent("History")
        try BrowserHistoryFixture.buildChromium(at: dbURL)

        let reader = try ChromiumHistoryReader(browser: .chrome, liveURL: dbURL)
        let rows = try reader.visits(after: 0, limit: 100)
        let typed = rows.first { $0.url == "https://example.com/typed" }
        XCTAssertEqual(typed?.isTypedUrl, true)
    }

    func testChromeReaderRespectsCursor() throws {
        let dbURL = tempDir.appendingPathComponent("History")
        try BrowserHistoryFixture.buildChromium(at: dbURL)

        let reader = try ChromiumHistoryReader(browser: .chrome, liveURL: dbURL)
        let firstPage = try reader.visits(after: 0, limit: 1)
        XCTAssertEqual(firstPage.count, 1)
        guard let firstID = Int64(firstPage[0].localId) else {
            return XCTFail("expected numeric localId")
        }
        let secondPage = try reader.visits(after: firstID, limit: 100)
        XCTAssertEqual(secondPage.count, 2)
        XCTAssertFalse(secondPage.contains { $0.url == firstPage[0].url })
    }

    func testArcReaderUsesArcBrowserPrefix() throws {
        let dbURL = tempDir.appendingPathComponent("History")
        try BrowserHistoryFixture.buildChromium(at: dbURL)

        let reader = try ChromiumHistoryReader(browser: .arc, liveURL: dbURL)
        let rows = try reader.visits(after: 0, limit: 100)
        XCTAssertTrue(rows.allSatisfy { $0.browser == "arc" })
        XCTAssertTrue(rows.allSatisfy { $0.guid.hasPrefix("arc:") })
    }

    func testBraveReaderUsesBraveBrowserPrefix() throws {
        let dbURL = tempDir.appendingPathComponent("History")
        try BrowserHistoryFixture.buildChromium(at: dbURL)

        let reader = try ChromiumHistoryReader(browser: .brave, liveURL: dbURL)
        let rows = try reader.visits(after: 0, limit: 100)
        XCTAssertTrue(rows.allSatisfy { $0.browser == "brave" })
        XCTAssertTrue(rows.allSatisfy { $0.guid.hasPrefix("brave:") })
    }

    func testChromeReaderCopiesToTempBeforeOpening() throws {
        // Sanity check: the reader's temp copy lives at a different path
        // than the live URL it was given. We can't easily simulate Chrome
        // holding a write lock from a unit test, but we can confirm the
        // copy-to-temp behavior fires every read.
        let liveURL = tempDir.appendingPathComponent("History")
        try BrowserHistoryFixture.buildChromium(at: liveURL)

        let reader = try ChromiumHistoryReader(browser: .chrome, liveURL: liveURL)
        _ = try reader.visits(after: 0, limit: 100)

        // After construction the temp dir should exist somewhere
        // distinct from `tempDir`.
        let mirroredPath = liveURL.deletingLastPathComponent().path
        let tempRoot = FileManager.default.temporaryDirectory.path
        // The reader created its own subdir under NSTemporaryDirectory.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tempRoot)) ?? []
        let mine = entries.filter { $0.hasPrefix("maraithon-chrome-") }
        XCTAssertFalse(mine.isEmpty, "expected a maraithon-chrome-* dir under temp")
        // None of those temp directories should equal the live db dir.
        XCTAssertFalse(mine.map { (tempRoot as NSString).appendingPathComponent($0) }
                          .contains { $0 == mirroredPath })
    }

    func testWebKitTimestampConversion() {
        // 13_293_454_400_000_000 = WebKit microseconds for 2022-04-26
        // (978_307_200 + 11_644_473_600 + 670_673_600 — but we
        // don't need exactness here; we just want a stable known
        // round-trip).
        let micros = BrowserHistoryFixture.webkit(seconds: 800_000_000)
        let date = ChromiumHistoryReader.date(fromWebKitMicroseconds: micros)
        XCTAssertNotNil(date)
        // Inverse: 800_000_000 seconds after 2001 = roughly year 2026.
        let unix = date!.timeIntervalSince1970
        // Expected unix = 978_307_200 + 800_000_000 = 1_778_307_200
        XCTAssertEqual(unix, 1_778_307_200, accuracy: 1.0)
    }

    func testWebKitTimestampZeroIsNil() {
        XCTAssertNil(ChromiumHistoryReader.date(fromWebKitMicroseconds: 0))
        XCTAssertNil(ChromiumHistoryReader.date(fromWebKitMicroseconds: -1))
    }

    // MARK: - Safari

    func testSafariReaderJoinsItemsWithLatestVisit() throws {
        let dbURL = tempDir.appendingPathComponent("History.db")
        try BrowserHistoryFixture.buildSafari(at: dbURL)

        let reader = try SafariHistoryReader(liveURL: dbURL)
        let rows = try reader.visits(after: 0, limit: 100)
        XCTAssertEqual(rows.count, 2)

        let byUrl = Dictionary(uniqueKeysWithValues: rows.map { ($0.url, $0) })
        let blog = byUrl["https://blog.example.org/post"]
        XCTAssertEqual(blog?.title, "Example blog post")
        XCTAssertEqual(blog?.host, "blog.example.org")
        XCTAssertEqual(blog?.browser, "safari")
        XCTAssertTrue(blog?.guid.hasPrefix("safari:") ?? false)
        XCTAssertNotNil(blog?.lastVisitedAt)
        XCTAssertEqual(blog?.isTypedUrl, false)
    }

    func testSafariReaderUsesDomainExpansionWhenURLLacksHost() throws {
        let dbURL = tempDir.appendingPathComponent("History.db")
        try BrowserHistoryFixture.buildSafari(at: dbURL, rows: [
            BrowserHistoryFixture.SafariRow(
                url: "some-weird-string",
                domain: "fallback.example.com",
                visitCount: 1,
                title: "Weird",
                visitTimeSeconds: 800_000_000
            )
        ])
        let reader = try SafariHistoryReader(liveURL: dbURL)
        let rows = try reader.visits(after: 0, limit: 100)
        XCTAssertEqual(rows.first?.host, "fallback.example.com")
    }

    // MARK: - Browser enum

    func testBrowserAllCasesAreLowercaseRawValues() {
        XCTAssertEqual(Browser.chrome.rawValue, "chrome")
        XCTAssertEqual(Browser.safari.rawValue, "safari")
        XCTAssertEqual(Browser.arc.rawValue, "arc")
        XCTAssertEqual(Browser.brave.rawValue, "brave")
        XCTAssertEqual(Browser.allCases.count, 4)
    }
}
