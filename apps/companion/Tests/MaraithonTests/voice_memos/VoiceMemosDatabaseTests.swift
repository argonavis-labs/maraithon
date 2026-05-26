import XCTest
@testable import Maraithon

final class VoiceMemosDatabaseTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-memos-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("CloudRecordings.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadsRecordingsAndResolvesFileSize() throws {
        try VoiceMemosFixture.build(at: dbURL)
        let db = try VoiceMemosDatabase(url: dbURL)

        let rows = try db.recordingsAfter(rowid: 0)
        // Three fixture rows but one has a missing .m4a → should be skipped.
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first.rowID, 1)
        XCTAssertEqual(first.uniqueID, "VM-UUID-0001")
        XCTAssertEqual(first.customLabel, "Team standup")
        XCTAssertEqual(first.fileSizeBytes, 482_948)
        XCTAssertNotNil(first.audioURL)
        XCTAssertEqual(first.durationSeconds, 65.5, accuracy: 0.001)
    }

    func testCursorBoundedQuery() throws {
        try VoiceMemosFixture.build(at: dbURL)
        let db = try VoiceMemosDatabase(url: dbURL)

        let afterFirst = try db.recordingsAfter(rowid: 1)
        XCTAssertEqual(afterFirst.map(\.rowID), [2])
        let afterLast = try db.recordingsAfter(rowid: 3)
        XCTAssertEqual(afterLast, [])
    }

    func testLimitCapsRowCount() throws {
        try VoiceMemosFixture.build(at: dbURL)
        let db = try VoiceMemosDatabase(url: dbURL)

        let rows = try db.recordingsAfter(rowid: 0, limit: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.rowID, 1)
    }

    func testMissingAudioFileIsSkipped() throws {
        // Single row whose .m4a is intentionally never written.
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 42,
                uniqueID: "VM-MISSING",
                customLabel: "Synced away",
                dateSeconds: 779_500_000,
                durationSeconds: 10,
                relativePath: "ghost.m4a",
                fileBytes: nil
            )
        ])
        let db = try VoiceMemosDatabase(url: dbURL)
        XCTAssertEqual(try db.recordingsAfter(rowid: 0), [])
    }

    func testDateMappingMatchesAppleEpoch() throws {
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-EPOCH",
                customLabel: "T-zero",
                dateSeconds: 0,
                durationSeconds: 1,
                relativePath: "t0.m4a",
                fileBytes: 8
            )
        ])
        let db = try VoiceMemosDatabase(url: dbURL)
        let rows = try db.recordingsAfter(rowid: 0)
        XCTAssertEqual(rows.first?.createdAt, VoiceMemosDatabase.appleEpoch)
    }
}
