import XCTest
@testable import Maraithon

final class NotesDatabaseTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-db-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("NoteStore.sqlite")
        try NotesFixture.build(at: dbURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadsAllNotesAfterCursorZero() throws {
        let db = try NotesDatabase(url: dbURL)
        let rows = try db.notesModifiedAfter(rowid: 0)
        // 5 notes seeded; folders share the table but the Z_ENT filter
        // strips them out.
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.guid).prefix(4).map { $0 },
                       ["NOTE-0001", "NOTE-0002", "NOTE-0003", "NOTE-0004"])
    }

    func testCoalescesTitleAcrossColumns() throws {
        let db = try NotesDatabase(url: dbURL)
        let rows = try db.notesModifiedAfter(rowid: 0)
        let byGuid = Dictionary(uniqueKeysWithValues: rows.map { ($0.guid, $0) })
        // ZTITLE1 populated.
        XCTAssertEqual(byGuid["NOTE-0001"]?.title, "Lunch with Sam")
        // Only ZTITLE2 populated — coalesce must surface it.
        XCTAssertEqual(byGuid["NOTE-0002"]?.title, "Move-out checklist")
        // Both populated — ZTITLE1 wins.
        XCTAssertEqual(byGuid["NOTE-0003"]?.title, "Roadmap Q3")
    }

    func testSyntheticGuidWhenIdentifierMissing() throws {
        let db = try NotesDatabase(url: dbURL)
        let rows = try db.notesModifiedAfter(rowid: 0)
        let orphan = rows.first { $0.snippet == "orphan snippet" }
        XCTAssertNotNil(orphan)
        XCTAssertTrue(orphan?.guid.hasPrefix("pk:") ?? false,
                      "missing ZIDENTIFIER should fall back to pk:N")
    }

    func testPinnedFlagAndFolderID() throws {
        let db = try NotesDatabase(url: dbURL)
        let rows = try db.notesModifiedAfter(rowid: 0)
        let pinned = rows.first { $0.guid == "NOTE-0002" }
        XCTAssertEqual(pinned?.isPinned, true)
        XCTAssertEqual(pinned?.folderRowID, 1)

        let unfoldered = rows.first { $0.guid == "NOTE-0004" }
        XCTAssertNil(unfoldered?.folderRowID)
    }

    func testFolderLookupResolvesName() throws {
        let db = try NotesDatabase(url: dbURL)
        XCTAssertEqual(try db.folder(rowid: 1), "Personal")
        XCTAssertEqual(try db.folder(rowid: 2), "Work")
        // Folder ROWID that doesn't exist.
        XCTAssertNil(try db.folder(rowid: 99))
    }

    func testCursorFiltersAlreadySyncedRows() throws {
        let db = try NotesDatabase(url: dbURL)
        let all = try db.notesModifiedAfter(rowid: 0)
        XCTAssertEqual(all.count, 5)
        guard let third = all.dropFirst(2).first else {
            return XCTFail("expected at least three rows")
        }
        let after = try db.notesModifiedAfter(rowid: third.rowID)
        XCTAssertEqual(after.count, all.count - 3,
                       "cursor advance trims older rows")
    }

    func testLimitClause() throws {
        let db = try NotesDatabase(url: dbURL)
        let limited = try db.notesModifiedAfter(rowid: 0, limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    func testBodyBlobIsReadOffJoin() throws {
        // Drop a fresh fixture that includes a body row so we can
        // assert the LEFT JOIN to ZICNOTEDATA fires and the raw blob
        // round-trips byte-identically.
        let altDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-db-body-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: altDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: altDir) }
        let altURL = altDir.appendingPathComponent("NoteStore.sqlite")
        let bodyText = "Body decoded end-to-end."
        let blob = NotesBodyFixture.blob(for: bodyText)
        try NotesFixture.buildEmpty(at: altURL)
        try NotesFixture.appendNote(
            at: altURL,
            NotesFixture.NoteRow(
                guid: "WITH-BODY",
                title1: "Has body",
                title2: nil,
                snippet: nil,
                creationSeconds: 779_500_000,
                modificationSeconds: 779_500_000,
                folderRowID: nil,
                isPinned: false,
                bodyBlob: blob
            )
        )

        let db = try NotesDatabase(url: altURL)
        let rows = try db.notesModifiedAfter(rowid: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.bodyBlob, blob)
        XCTAssertEqual(rows.first.flatMap { $0.bodyBlob.flatMap(NotesBodyDecoder.decode) },
                       bodyText)
    }

    func testBodyBlobIsNilWhenNoteDataRowMissing() throws {
        // The original fixture seeds no ZICNOTEDATA rows; every
        // existing note must report a nil bodyBlob so the JOIN logic
        // stays honest.
        let db = try NotesDatabase(url: dbURL)
        let rows = try db.notesModifiedAfter(rowid: 0)
        for row in rows {
            XCTAssertNil(row.bodyBlob,
                         "row \(row.guid) should have no body blob in the bare fixture")
        }
    }

    func testAppleSecondsToDate() {
        // 779_500_000 seconds past 2001-01-01 UTC is well into 2025.
        let date = NotesDatabase.date(fromAppleSeconds: 779_500_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let iso = formatter.string(from: date)
        XCTAssertTrue(iso.hasPrefix("2025-09-13"),
                      "got \(iso) — expected 2025-09-13 prefix")
    }
}
