import XCTest
@testable import Maraithon

final class NotesSourceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-source-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("NoteStore.sqlite")
        try NotesFixture.build(at: dbURL)

        defaultsSuiteName = "com.maraithon.companion.notes-tests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testSyncNowPostsAllSeededNotes() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()

        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "one POST issued")
        let batch = posted[0]
        XCTAssertEqual(batch.source, "notes")
        XCTAssertEqual(batch.notes.count, 5)

        let byGuid = Dictionary(uniqueKeysWithValues: batch.notes.map { ($0.guid, $0) })
        XCTAssertEqual(byGuid["NOTE-0001"]?.title, "Lunch with Sam")
        XCTAssertEqual(byGuid["NOTE-0001"]?.folder, "Personal")
        XCTAssertEqual(byGuid["NOTE-0003"]?.folder, "Work")
        XCTAssertEqual(byGuid["NOTE-0002"]?.isPinned, true)
        // Root-folder note serialises folder as null/absent.
        XCTAssertNil(byGuid["NOTE-0004"]?.folder)
    }

    @MainActor
    func testLocalIdMatchesPK() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        let batch = (await env.collector.snapshot())[0]
        for note in batch.notes {
            XCTAssertTrue(note.localId.hasPrefix("p:"),
                          "local_id should be p:<Z_PK>, got \(note.localId)")
        }
    }

    @MainActor
    func testCursorAdvancesAfterSuccessfulPost() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        let cursorAfterFirst = NotesCursor(defaults: defaultsSuite).lastSyncedRowID
        XCTAssertGreaterThan(cursorAfterFirst, 0)

        // Empty second sync — no new rows, no new POST.
        try await env.source.syncNow()
        let posted = await env.collector.snapshot()
        XCTAssertEqual(posted.count, 1, "no second POST when nothing new")

        // Append a row, expect a follow-up POST with just that one.
        try NotesFixture.appendNote(
            at: dbURL,
            NotesFixture.NoteRow(
                guid: "NOTE-LATER",
                title1: "Follow-up idea",
                title2: nil,
                snippet: "review tomorrow",
                creationSeconds: 779_510_000,
                modificationSeconds: 779_510_000,
                folderRowID: 1,
                isPinned: false
            )
        )
        try await env.source.syncNow()
        let postedAfter = await env.collector.snapshot()
        XCTAssertEqual(postedAfter.count, 2)
        XCTAssertEqual(postedAfter[1].notes.count, 1)
        XCTAssertEqual(postedAfter[1].notes.first?.guid, "NOTE-LATER")
        XCTAssertGreaterThan(
            NotesCursor(defaults: defaultsSuite).lastSyncedRowID,
            cursorAfterFirst
        )
    }

    @MainActor
    func testCursorDoesNotAdvanceWhenPostFails() async throws {
        // Stub transport returns 500 for every request.
        let env = makeEnvironment(httpStatus: 500)

        do {
            try await env.source.syncNow()
            XCTFail("expected POST failure to propagate")
        } catch {
            // Expected — server returned 5xx.
        }
        XCTAssertEqual(
            NotesCursor(defaults: defaultsSuite).lastSyncedRowID,
            0,
            "cursor stays at zero on failed POST so the next cycle retries"
        )
        if case .error = env.source.statusPublisher.displayedState() {
            // expected
        } else {
            XCTFail("failed sync should render red, got \(env.source.statusPublisher.displayedState())")
        }
    }

    @MainActor
    func testClearLocalStateResetsCursor() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        XCTAssertGreaterThan(NotesCursor(defaults: defaultsSuite).lastSyncedRowID, 0)
        env.source.clearLocalState()
        XCTAssertEqual(NotesCursor(defaults: defaultsSuite).lastSyncedRowID, 0)
    }

    @MainActor
    func testRestartResumesFromPersistedCursor() async throws {
        let firstEnv = makeEnvironment()
        try await firstEnv.source.syncNow()
        let cursorAfterFirst = NotesCursor(defaults: defaultsSuite).lastSyncedRowID
        XCTAssertGreaterThan(cursorAfterFirst, 0)

        try NotesFixture.appendNote(
            at: dbURL,
            NotesFixture.NoteRow(
                guid: "NOTE-RESTART",
                title1: "After restart",
                title2: nil,
                snippet: nil,
                creationSeconds: 779_520_000,
                modificationSeconds: 779_520_000,
                folderRowID: nil,
                isPinned: false
            )
        )

        let secondEnv = makeEnvironment()
        try await secondEnv.source.syncNow()
        let posted = await secondEnv.collector.snapshot()
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].notes.count, 1)
        XCTAssertEqual(posted[0].notes.first?.guid, "NOTE-RESTART")
    }

    @MainActor
    func testDecodesBodyEndToEnd() async throws {
        // Append a note backed by a synthetic ZICNOTEDATA blob and run
        // a full sync cycle; the posted payload must carry the decoded
        // plain-text body and a "plain" body_format.
        let body = "End-to-end body payload."
        let blob = NotesBodyFixture.blob(for: body)
        try NotesFixture.appendNote(
            at: dbURL,
            NotesFixture.NoteRow(
                guid: "NOTE-BODY",
                title1: "Has body",
                title2: nil,
                snippet: nil,
                creationSeconds: 779_530_000,
                modificationSeconds: 779_530_000,
                folderRowID: nil,
                isPinned: false,
                bodyBlob: blob
            )
        )
        let env = makeEnvironment()
        try await env.source.syncNow()
        let batch = (await env.collector.snapshot())[0]
        let note = batch.notes.first { $0.guid == "NOTE-BODY" }
        XCTAssertEqual(note?.body, body)
        XCTAssertEqual(note?.bodyFormat, "plain")
    }

    @MainActor
    func testBodyAbsentForBodylessNotes() async throws {
        // Notes that don't have a ZICNOTEDATA row must ship with body
        // and body_format both nil so the server stores neither.
        let env = makeEnvironment()
        try await env.source.syncNow()
        let batch = (await env.collector.snapshot())[0]
        for note in batch.notes {
            XCTAssertNil(note.body, "no body row → body is nil for \(note.guid)")
            XCTAssertNil(note.bodyFormat, "no body row → body_format is nil for \(note.guid)")
        }
    }

    @MainActor
    func testTimestampsAreISO8601() async throws {
        let env = makeEnvironment()
        try await env.source.syncNow()
        let batch = (await env.collector.snapshot())[0]
        let note = batch.notes.first { $0.guid == "NOTE-0001" }
        // Format must match what the server expects (`.withInternetDateTime`,
        // no fractional seconds).
        XCTAssertEqual(note?.createdAt, "2025-09-13T23:46:40Z")
        XCTAssertEqual(note?.modifiedAt, "2025-09-13T23:48:20Z")
    }

    @MainActor
    func testAuthorizationDeniedMapsToFullDiskAccessIssue() {
        let openError = NotesDatabase.DatabaseError.openFailed(
            code: 23,
            message: "authorization denied"
        )
        XCTAssertEqual(
            NotesSource.accessIssueReason(for: openError),
            "notes_full_disk_access_required"
        )

        let prepareError = NotesDatabase.DatabaseError.prepareFailed(
            message: "authorization denied"
        )
        XCTAssertEqual(
            NotesSource.accessIssueReason(for: prepareError),
            "notes_full_disk_access_required"
        )

        let schemaError = NotesDatabase.DatabaseError.entityMissing(name: "ICNote")
        XCTAssertNil(NotesSource.accessIssueReason(for: schemaError))
    }

    // MARK: - Helpers

    @MainActor
    private struct Environment {
        let source: NotesSource
        let collector: PostCollector
    }

    @MainActor
    private func makeEnvironment(httpStatus: Int = 200) -> Environment {
        let log = EventLog(capacity: 128)
        let collector = PostCollector()
        let baseURL = URL(string: "https://test.maraithon.invalid")!
        let deviceId = UUID()
        let stubTransport: MaraithonClient.Transport = { request in
            // Pull the gzipped body out so we can decode it back into a
            // typed batch for assertions. The wire path uses gzip; tests
            // need to mirror that to exercise the full encoder.
            let bodyData = request.httpBody ?? Data()
            let plain: Data
            if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
                plain = (try? Gzip.decompress(bodyData)) ?? bodyData
            } else {
                plain = bodyData
            }
            if let batch = try? JSONDecoder().decode(NotesIngestBatch.self, from: plain) {
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
        let ingest = NotesIngest(
            baseURL: baseURL,
            tokenProvider: { "test-token" },
            transport: stubTransport
        )
        let cursor = NotesCursor(defaults: defaultsSuite)
        let source = NotesSource(
            databaseURL: dbURL,
            cursor: cursor,
            eventLog: log,
            ingest: ingest,
            deviceIdProvider: { deviceId },
            pollInterval: 3600  // never fires during a test
        )
        return Environment(source: source, collector: collector)
    }
}

/// Thread-safe accumulator for decoded `NotesIngestBatch` values. The
/// `NotesIngest` transport closure is `@Sendable`, so we route batches
/// through an actor to keep the test side strict-concurrency-clean.
actor PostCollector {
    private var batches: [NotesIngestBatch] = []

    func append(_ batch: NotesIngestBatch) {
        batches.append(batch)
    }

    func snapshot() -> [NotesIngestBatch] {
        batches
    }
}
