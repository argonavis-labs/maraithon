import Foundation
import SQLite3

/// Builds a tiny SQLite database that mirrors the subset of Voice Memos'
/// `CloudRecordings.db` schema the source actually reads (Core Data
/// `ZCLOUDRECORDING` table). The fixture also drops zero-byte `.m4a` files
/// next to the database at the paths the rows reference so the file-size
/// lookup has something real to stat.
///
/// Extending the source to consume more columns means extending the
/// fixture too — that's a feature, not a bug.
enum VoiceMemosFixture {
    struct Row {
        let pk: Int64
        let uniqueID: String
        let customLabel: String?
        /// Seconds since Apple's Core Data epoch (2001-01-01 UTC).
        let dateSeconds: Double
        let durationSeconds: Double
        /// Relative path to the `.m4a`, joined onto the database
        /// directory. `nil` simulates a row missing `ZPATH` entirely.
        let relativePath: String?
        /// File size to write at `relativePath`. `nil` means "don't write
        /// the audio file" — the source should skip the row.
        let fileBytes: Int?
    }

    /// Builds a `CloudRecordings.db`-shaped database at `dbURL` plus the
    /// audio files implied by the rows. Returns the rows for the test to
    /// assert against if it wants.
    @discardableResult
    static func build(at dbURL: URL, rows: [Row] = defaultRows) throws -> [Row] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openStatus = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "VoiceMemosFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }

        try exec(db, schemaSQL)

        for row in rows {
            try insertRecording(db, row)
            if let rel = row.relativePath, let bytes = row.fileBytes {
                let audioURL = dbURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(rel)
                let parent = audioURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                let data = Data(count: bytes)
                try data.write(to: audioURL)
            }
        }
        return rows
    }

    /// Append a recording row + its audio file post-build, used by the
    /// "new row after a poll" test.
    static func appendRow(at dbURL: URL, _ row: Row) throws {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "VoiceMemosFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }
        try insertRecording(db, row)
        if let rel = row.relativePath, let bytes = row.fileBytes {
            let audioURL = dbURL
                .deletingLastPathComponent()
                .appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: audioURL)
        }
    }

    /// Default fixture set covering the cases the source has to handle:
    ///   * a user-renamed recording (custom label set)
    ///   * an unlabelled recording (custom label nil → derived title)
    ///   * a recording whose `.m4a` is missing on disk (should be skipped)
    static let defaultRows: [Row] = [
        Row(
            pk: 1,
            uniqueID: "VM-UUID-0001",
            customLabel: "Team standup",
            dateSeconds: 779_500_000,
            durationSeconds: 65.5,
            relativePath: "20260301 121314.m4a",
            fileBytes: 482_948
        ),
        Row(
            pk: 2,
            uniqueID: "VM-UUID-0002",
            customLabel: nil,
            dateSeconds: 779_500_500,
            durationSeconds: 12.0,
            relativePath: "20260301 122000.m4a",
            fileBytes: 92_400
        ),
        Row(
            pk: 3,
            uniqueID: "VM-UUID-0003",
            customLabel: "Synced-away clip",
            dateSeconds: 779_501_000,
            durationSeconds: 30.0,
            // Path is set but the file is missing — simulates an iCloud-
            // evicted recording.
            relativePath: "20260301 123100.m4a",
            fileBytes: nil
        )
    ]

    // MARK: - Internals

    private static func insertRecording(_ db: OpaquePointer, _ row: Row) throws {
        let sql = """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZUNIQUEID, ZCUSTOMLABEL, ZDATE, ZDURATION, ZPATH)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "VoiceMemosFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, row.pk)
        sqlite3_bind_text(stmt, 2, row.uniqueID, -1, sqliteTransient)
        if let label = row.customLabel {
            sqlite3_bind_text(stmt, 3, label, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, row.dateSeconds)
        sqlite3_bind_double(stmt, 5, row.durationSeconds)
        if let rel = row.relativePath {
            sqlite3_bind_text(stmt, 6, rel, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "VoiceMemosFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &err)
        if status != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(
                domain: "VoiceMemosFixture",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    /// Minimal subset of the Core Data-managed schema. Real `CloudRecordings.db`
    /// also has `ZFOLDER`, `ZTRANSCRIPTION`, etc. — the source reads none
    /// of those, so we leave them out.
    private static let schemaSQL = """
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY,
            ZUNIQUEID TEXT NOT NULL,
            ZCUSTOMLABEL TEXT,
            ZDATE REAL NOT NULL,
            ZDURATION REAL NOT NULL,
            ZPATH TEXT
        );
        """

    /// `SQLITE_TRANSIENT` macro reconstructed for Swift — same trick as
    /// `IMessageFixture`.
    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}
