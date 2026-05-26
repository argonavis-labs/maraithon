import Foundation
import SQLite3

/// Builds a tiny but realistic SQLite database that mirrors the subset
/// of Apple's `NoteStore.sqlite` schema the Notes source touches.
///
/// The fixture only creates the columns the source reads. Apple's real
/// `ZICCLOUDSYNCINGOBJECT` has dozens of columns shared between every
/// entity type (notes, folders, accounts, attachments, …); we keep only
/// the slim subset our queries reference, plus `Z_ENT` so the entity
/// filter behaves the same way it does in production.
///
/// Mirrors `IMessageFixture` in spirit: extending the source to consume
/// new columns means extending this fixture too.
enum NotesFixture {
    /// Entity IDs we hand out to the fixture rows. Real Notes DBs pick
    /// numbers in the low double-digits; the exact values don't matter
    /// because the source resolves them dynamically through
    /// `Z_PRIMARYKEY`.
    static let noteEntityID: Int64 = 11
    static let folderEntityID: Int64 = 13

    struct NoteRow {
        let guid: String?
        let title1: String?
        let title2: String?
        let snippet: String?
        let creationSeconds: Double?
        let modificationSeconds: Double?
        let folderRowID: Int64?
        let isPinned: Bool
        /// Raw `ZICNOTEDATA.ZDATA` blob, written into a companion row
        /// joined to the note by `ZNOTE = Z_PK`. `nil` means no body
        /// row was seeded — equivalent to a never-opened note.
        let bodyBlob: Data?

        init(
            guid: String?,
            title1: String?,
            title2: String?,
            snippet: String?,
            creationSeconds: Double?,
            modificationSeconds: Double?,
            folderRowID: Int64?,
            isPinned: Bool,
            bodyBlob: Data? = nil
        ) {
            self.guid = guid
            self.title1 = title1
            self.title2 = title2
            self.snippet = snippet
            self.creationSeconds = creationSeconds
            self.modificationSeconds = modificationSeconds
            self.folderRowID = folderRowID
            self.isPinned = isPinned
            self.bodyBlob = bodyBlob
        }
    }

    static func build(at url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openStatus = sqlite3_open_v2(url.path, &db, flags, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "NotesFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }

        try exec(db, schemaSQL)

        // Register entity IDs in Z_PRIMARYKEY so `NotesDatabase` can
        // resolve `ICNote` and `ICFolder` the way it would in prod.
        try exec(db, "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (\(noteEntityID), 'ICNote');")
        try exec(db, "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (\(folderEntityID), 'ICFolder');")

        // Folders. We seed two so we can assert the join works for
        // notes spread across folders.
        try insertFolder(db, title: "Personal")    // Z_PK = 1
        try insertFolder(db, title: "Work")        // Z_PK = 2

        let creation: Double = 779_500_000   // arbitrary Apple-epoch seconds
        let modification: Double = 779_500_100

        // Note rows. The order here is the order Z_PK will be assigned.
        let notes: [NoteRow] = [
            // Canonical row: title in ZTITLE1, snippet present, folder 1.
            NoteRow(
                guid: "NOTE-0001",
                title1: "Lunch with Sam",
                title2: nil,
                snippet: "Confirmed for Friday",
                creationSeconds: creation,
                modificationSeconds: modification,
                folderRowID: 1,
                isPinned: false
            ),
            // Older-OS shape: title only in ZTITLE2 — coalesce must
            // still surface a non-nil title.
            NoteRow(
                guid: "NOTE-0002",
                title1: nil,
                title2: "Move-out checklist",
                snippet: "Cancel utilities",
                creationSeconds: creation + 10,
                modificationSeconds: modification + 10,
                folderRowID: 1,
                isPinned: true
            ),
            // Mixed: title in both columns; ZTITLE1 wins via COALESCE.
            NoteRow(
                guid: "NOTE-0003",
                title1: "Roadmap Q3",
                title2: "Roadmap Q3 (legacy)",
                snippet: nil,
                creationSeconds: creation + 20,
                modificationSeconds: modification + 20,
                folderRowID: 2,
                isPinned: false
            ),
            // No folder assigned (root note).
            NoteRow(
                guid: "NOTE-0004",
                title1: "Quick thought",
                title2: nil,
                snippet: "Buy milk",
                creationSeconds: creation + 30,
                modificationSeconds: modification + 30,
                folderRowID: nil,
                isPinned: false
            ),
            // Pathological row: no identifier (forces synthetic
            // pk:N guid fallback) and no title at all.
            NoteRow(
                guid: nil,
                title1: nil,
                title2: nil,
                snippet: "orphan snippet",
                creationSeconds: creation + 40,
                modificationSeconds: modification + 40,
                folderRowID: 1,
                isPinned: false
            )
        ]

        for note in notes {
            try insertNote(db, note)
        }
    }

    /// Create a fresh fixture DB with only the schema + entity-id rows
    /// — no seeded notes or folders. Useful for tests that need full
    /// control over the row set (e.g. body-blob round-trip).
    static func buildEmpty(at url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openStatus = sqlite3_open_v2(url.path, &db, flags, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "NotesFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }
        try exec(db, schemaSQL)
        try exec(db, "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (\(noteEntityID), 'ICNote');")
        try exec(db, "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (\(folderEntityID), 'ICFolder');")
    }

    /// Append a single note to an existing fixture DB. Used by the
    /// cursor / restart tests.
    static func appendNote(at url: URL, _ row: NoteRow) throws {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "NotesFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }
        try insertNote(db, row)
    }

    // MARK: - Internals

    private static func insertFolder(_ db: OpaquePointer, title: String) throws {
        let sql = """
            INSERT INTO ZICCLOUDSYNCINGOBJECT
              (Z_ENT, ZTITLE2)
            VALUES (?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NotesFixture", code: 10, userInfo: nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, folderEntityID)
        sqlite3_bind_text(stmt, 2, title, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "NotesFixture",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
    }

    private static func insertNote(_ db: OpaquePointer, _ row: NoteRow) throws {
        let sql = """
            INSERT INTO ZICCLOUDSYNCINGOBJECT
              (Z_ENT, ZIDENTIFIER, ZTITLE1, ZTITLE2, ZSNIPPET,
               ZCREATIONDATE1, ZMODIFICATIONDATE1, ZFOLDER, ZISPINNED)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "NotesFixture",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, noteEntityID)
        bindOptionalText(stmt, 2, row.guid)
        bindOptionalText(stmt, 3, row.title1)
        bindOptionalText(stmt, 4, row.title2)
        bindOptionalText(stmt, 5, row.snippet)
        bindOptionalDouble(stmt, 6, row.creationSeconds)
        bindOptionalDouble(stmt, 7, row.modificationSeconds)
        if let folder = row.folderRowID {
            sqlite3_bind_int64(stmt, 8, folder)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int(stmt, 9, row.isPinned ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "NotesFixture",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        if let blob = row.bodyBlob {
            let notePK = sqlite3_last_insert_rowid(db)
            try insertNoteData(db, notePK: notePK, blob: blob)
        }
    }

    /// Insert the gzipped-protobuf body row into the companion
    /// `ZICNOTEDATA` table. Mirrors the join the production schema
    /// uses (`ZICNOTEDATA.ZNOTE = ZICCLOUDSYNCINGOBJECT.Z_PK`) so the
    /// `NotesDatabase` LEFT JOIN picks the blob up unchanged.
    private static func insertNoteData(_ db: OpaquePointer, notePK: Int64, blob: Data) throws {
        let sql = "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "NotesFixture",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, notePK)
        _ = blob.withUnsafeBytes { raw -> Int32 in
            // SQLITE_TRANSIENT so SQLite copies the bytes — `Data` only
            // lends pointers to the closure scope.
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(blob.count), sqliteTransient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "NotesFixture",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &err)
        if status != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(
                domain: "NotesFixture",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    private static let schemaSQL = """
        CREATE TABLE Z_PRIMARYKEY (
            Z_ENT INTEGER NOT NULL,
            Z_NAME TEXT NOT NULL,
            Z_SUPER INTEGER DEFAULT 0,
            Z_MAX INTEGER DEFAULT 0
        );
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            Z_PK INTEGER PRIMARY KEY AUTOINCREMENT,
            Z_ENT INTEGER NOT NULL,
            ZIDENTIFIER TEXT,
            ZTITLE1 TEXT,
            ZTITLE2 TEXT,
            ZSNIPPET TEXT,
            ZCREATIONDATE1 REAL,
            ZMODIFICATIONDATE1 REAL,
            ZFOLDER INTEGER,
            ZISPINNED INTEGER DEFAULT 0
        );
        CREATE TABLE ZICNOTEDATA (
            Z_PK INTEGER PRIMARY KEY AUTOINCREMENT,
            ZNOTE INTEGER,
            ZDATA BLOB
        );
        """

    /// `SQLITE_TRANSIENT` is a macro Apple's SQLite headers define as
    /// `((sqlite3_destructor_type)-1)`. The macro doesn't survive the
    /// Swift importer, so we recreate it by bit-casting `-1`.
    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}
