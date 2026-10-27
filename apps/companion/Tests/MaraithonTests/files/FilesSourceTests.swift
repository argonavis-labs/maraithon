import XCTest
@testable import Maraithon

final class FilesSourceTests: XCTestCase {
    private var tempRoot: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-source-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        defaultsSuiteName = "com.maraithon.companion.files-tests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testSyncNowPushesScannedFiles() async throws {
        try writeFile(at: "notes.md", body: "shipping the v2 files source")
        try writeFile(at: "todo.txt", body: "buy milk")

        let env = makeEnvironment()
        try await env.source.syncNow()

        let payloads = await env.collector.snapshot()
        XCTAssertEqual(payloads.count, 1, "one POST issued")
        let batch = payloads[0]
        XCTAssertEqual(batch.source, "files")
        let names = batch.files.map { $0.filename ?? "?" }.sorted()
        XCTAssertEqual(names, ["notes.md", "todo.txt"])

        // Both files should ship base64-encoded text content.
        for file in batch.files {
            XCTAssertNotNil(file.textContentBase64, "\(file.filename ?? "?") should ship text")
            XCTAssertFalse(file.textTruncated)
        }
    }

    @MainActor
    func testCursorAdvancesAfterSuccessfulPost() async throws {
        try writeFile(at: "a.md", body: "first")

        let env = makeEnvironment()
        try await env.source.syncNow()
        let snapshotAfterFirst = FilesCursor(defaults: defaultsSuite).snapshot()
        XCTAssertEqual(snapshotAfterFirst.count, 1)

        // Empty second sync — no new rows, no new POST.
        try await env.source.syncNow()
        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "no second POST when nothing new")

        // Add a new file and run another cycle. Only the new file
        // should be pushed.
        try writeFile(at: "b.md", body: "second")
        try await env.source.syncNow()
        let postedAfter = await env.collector.snapshot()
        XCTAssertEqual(postedAfter.count, 2)
        XCTAssertEqual(postedAfter[1].files.count, 1)
        XCTAssertEqual(postedAfter[1].files.first?.filename, "b.md")
    }

    @MainActor
    func testCursorDoesNotAdvanceWhenPostFails() async throws {
        try writeFile(at: "a.md", body: "first")

        let env = makeEnvironment(httpStatus: 500)
        do {
            try await env.source.syncNow()
            XCTFail("expected POST failure to propagate")
        } catch {
            // Expected — server returned 5xx.
        }
        let snapshot = FilesCursor(defaults: defaultsSuite).snapshot()
        XCTAssertTrue(snapshot.isEmpty,
                      "cursor stays empty on failed POST so the next cycle retries")
    }

    @MainActor
    func testClearLocalStateResetsCursor() async throws {
        try writeFile(at: "a.md", body: "first")

        let env = makeEnvironment()
        try await env.source.syncNow()
        XCTAssertFalse(FilesCursor(defaults: defaultsSuite).snapshot().isEmpty)

        env.source.clearLocalState()
        XCTAssertTrue(FilesCursor(defaults: defaultsSuite).snapshot().isEmpty)
    }

    @MainActor
    func testIdAndSymbolMatchSpec() {
        let env = makeEnvironment()
        XCTAssertEqual(env.source.id, "files")
        XCTAssertEqual(env.source.displayName, "Files")
        XCTAssertEqual(env.source.symbol, "folder")
    }

    @MainActor
    func testPrivacyFiltersAreEnforcedEndToEnd() async throws {
        // Mix allowed and disallowed paths to verify the source
        // (which delegates to the scanner) drops the disallowed ones
        // before they ever ship.
        try writeFile(at: "Projects/ok.md", body: "ok body")
        try writeFile(at: "Projects/.env", body: "SECRET=topsecret")
        try writeFile(at: "Projects/.git/HEAD", body: "abc123")
        try writeFile(at: "Projects/node_modules/lodash/index.js", body: "module.exports")

        let env = makeEnvironment()
        try await env.source.syncNow()
        let batch = (await env.collector.snapshot())[0]
        let names = batch.files.map { $0.filename ?? "?" }.sorted()
        XCTAssertEqual(names, ["ok.md"])
    }

    // MARK: - Helpers

    private func writeFile(at relativePath: String, body: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    private struct Environment {
        let source: FilesSource
        let collector: FilesPostCollector
    }

    @MainActor
    private func makeEnvironment(httpStatus: Int = 200) -> Environment {
        let log = EventLog(capacity: 128)
        let collector = FilesPostCollector()
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
            if let batch = try? JSONDecoder.iso8601().decode(FilesIngestBatch.self, from: plain) {
                await collector.append(batch)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: httpStatus,
                httpVersion: nil,
                headerFields: nil
            )!
            let responseBody = "{\"accepted\":\(httpStatus == 200 ? 1 : 0),\"duplicate\":0}"
                .data(using: .utf8) ?? Data()
            return (responseBody, response)
        }
        let ingest = FilesIngest(
            baseURL: baseURL,
            tokenProvider: { "test-token" },
            transport: stubTransport
        )
        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let database = FilesDatabase(scanner: scanner)
        let cursor = FilesCursor(defaults: defaultsSuite)
        let source = FilesSource(
            database: database,
            cursor: cursor,
            eventLog: log,
            ingest: ingest,
            deviceIdProvider: { deviceId },
            pollInterval: 3600  // never fires during a test
        )
        return Environment(source: source, collector: collector)
    }
}

/// Thread-safe accumulator for decoded `FilesIngestBatch` values. The
/// `FilesIngest` transport closure is `@Sendable`, so we route batches
/// through an actor to keep the test side strict-concurrency-clean.
actor FilesPostCollector {
    private var batches: [FilesIngestBatch] = []

    func append(_ batch: FilesIngestBatch) {
        batches.append(batch)
    }

    func snapshot() -> [FilesIngestBatch] {
        batches
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
