import Foundation
import SQLite3

/// Read-only wrapper over the Apple Notes Core Data SQLite store at
/// `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
/// Opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` so Apple's
/// Notes.app process never blocks us and vice versa. The init takes an
/// explicit database URL so tests can hand in a synthetic SQLite file.
///
/// Notes are persisted by Core Data using its `Z`-prefixed column
/// convention. The two columns we read off the note row are
/// `ZCREATIONDATE1` / `ZMODIFICATIONDATE1`, both stored as the standard
/// Core Data Apple epoch (`seconds since 2001-01-01 UTC`, real-typed).
/// Conversion to Foundation `Date` happens here so callers stay clean.
///
/// Both `ZTITLE1` and `ZTITLE2` exist on `ZICCLOUDSYNCINGOBJECT` because
/// the Notes schema has changed across macOS releases — different point
/// releases write the title to one column or the other and sometimes both.
/// We coalesce in SQL so a caller never sees a "wrong" empty title just
/// because Apple shuffled which column is canonical this OS version.
final class NotesDatabase: @unchecked Sendable {
    /// Default location of the user's Apple Notes store.
    static var defaultDatabaseURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent("group.com.apple.notes", isDirectory: true)
            .appendingPathComponent("NoteStore.sqlite", isDirectory: false)
    }

    /// Apple's epoch (2001-01-01 UTC), exposed for tests. Same constant
    /// `IMessageDatabase` uses, recomputed locally so the modules stay
    /// independent.
    static let appleEpoch: Date = {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private var handle: OpaquePointer?

    /// Cached entity IDs (`Z_ENT`) for `ICNote` and `ICFolder`, resolved
    /// once at init from `Z_PRIMARYKEY`. They are stable for the lifetime
    /// of the database file but can differ across users and macOS
    /// versions, so we look them up rather than hard-coding.
    private let noteEntityID: Int64
    private let folderEntityID: Int64?

    init(url: URL = NotesDatabase.defaultDatabaseURL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw DatabaseError.openFailed(code: status, message: message)
        }
        self.handle = db

        // Resolve entity IDs up front; the queries below filter on
        // `Z_ENT` so a misread would silently return zero rows otherwise.
        guard let noteID = try Self.entityID(db: db, name: "ICNote") else {
            sqlite3_close(db)
            self.handle = nil
            throw DatabaseError.entityMissing(name: "ICNote")
        }
        self.noteEntityID = noteID
        // Folders are optional — a brand-new account may have no folder
        // rows yet; we still want note reads to succeed.
        self.folderEntityID = try Self.entityID(db: db, name: "ICFolder")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// Errors surfaced from the SQLite layer. Callers translate these
    /// into `SourceState.error` for the UI.
    enum DatabaseError: Error, Equatable {
        case openFailed(code: Int32, message: String)
        case prepareFailed(message: String)
        case stepFailed(message: String)
        case entityMissing(name: String)
    }

    /// Read every note with `Z_PK > rowid`, ordered ASC, capped at
    /// `limit`. Returns an empty array when there is nothing new.
    ///
    /// We LEFT JOIN `ZICNOTEDATA` because the gzipped protobuf body
    /// lives in its `ZDATA` column rather than on the syncing-object
    /// row itself. The join is left-outer so notes that have been
    /// created but whose body row hasn't materialised yet still flush;
    /// their `bodyBlob` will simply be `nil`.
    func notesModifiedAfter(rowid: Int64, limit: Int = 200) throws -> [RawNote] {
        try notesWhere(predicate: "obj.Z_PK > ?", bound: rowid, ascending: true, limit: limit)
    }

    /// Newer-than walk: notes with `Z_PK > rowid` ordered DESC. Used by
    /// the live source so today's notes ship first.
    func notesNewerThan(rowid: Int64, limit: Int = 200) throws -> [RawNote] {
        try notesWhere(predicate: "obj.Z_PK > ?", bound: rowid, ascending: false, limit: limit)
    }

    /// Older-than walk: notes with `Z_PK < rowid` ordered DESC, used to
    /// backfill history once the newer-than walk is caught up.
    func notesOlderThan(rowid: Int64, limit: Int = 200) throws -> [RawNote] {
        try notesWhere(predicate: "obj.Z_PK < ?", bound: rowid, ascending: false, limit: limit)
    }

    private func notesWhere(
        predicate: String,
        bound: Int64,
        ascending: Bool,
        limit: Int
    ) throws -> [RawNote] {
        let order = ascending ? "ASC" : "DESC"
        // COALESCE the two title columns because the canonical column
        // shifts across macOS releases (see class-level note). Returning
        // a NULL title is fine — the source surfaces it as "(Untitled)"
        // or omits the field.
        let sql = """
            SELECT
                obj.Z_PK,
                obj.ZIDENTIFIER,
                COALESCE(obj.ZTITLE1, obj.ZTITLE2),
                obj.ZSNIPPET,
                obj.ZCREATIONDATE1,
                obj.ZMODIFICATIONDATE1,
                obj.ZFOLDER,
                COALESCE(obj.ZISPINNED, 0),
                data.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT AS obj
            LEFT JOIN ZICNOTEDATA AS data
                ON data.ZNOTE = obj.Z_PK
            WHERE obj.Z_ENT = ?
              AND \(predicate)
            ORDER BY obj.Z_PK \(order)
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, noteEntityID)
        sqlite3_bind_int64(stmt, 2, bound)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var rows: [RawNote] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let identifier = stringColumn(stmt, 1)
            let title = stringColumn(stmt, 2)
            let snippet = stringColumn(stmt, 3)
            let creation = doubleColumn(stmt, 4)
            let modification = doubleColumn(stmt, 5)
            let folderRowID: Int64? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(stmt, 6)
            let isPinned = sqlite3_column_int(stmt, 7) != 0
            let bodyBlob = blobColumn(stmt, 8)

            // ZIDENTIFIER is the stable UUID the server uses as `guid`.
            // If a row genuinely lacks one (corruption, mid-write), fall
            // back to a `pk:N` synthetic id so the row still flushes.
            let guid = identifier ?? "pk:\(rowID)"

            rows.append(
                RawNote(
                    rowID: rowID,
                    guid: guid,
                    title: title,
                    snippet: snippet,
                    createdAt: creation.map(Self.date(fromAppleSeconds:)),
                    modifiedAt: modification.map(Self.date(fromAppleSeconds:)),
                    folderRowID: folderRowID,
                    isPinned: isPinned,
                    bodyBlob: bodyBlob
                )
            )
        }
        return rows
    }

    /// Look up a folder's display name by its `Z_PK`. Returns `nil` when
    /// the folder row doesn't exist (e.g. the note is in the root) or
    /// when `ICFolder` is absent from the schema entirely.
    func folder(rowid: Int64) throws -> String? {
        guard let folderEntityID else { return nil }
        // Folders store their display name in `ZTITLE2` exclusively on
        // the macOS versions we've inspected, but COALESCE matches the
        // note-title behaviour for forward compat with a hypothetical
        // future schema swap.
        let stmt = try prepare("""
            SELECT COALESCE(ZTITLE2, ZTITLE1)
            FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_PK = ?
              AND Z_ENT = ?
            LIMIT 1;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        sqlite3_bind_int64(stmt, 2, folderEntityID)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return stringColumn(stmt, 0)
        }
        return nil
    }

    // MARK: - Helpers

    private static func entityID(db: OpaquePointer, name: String) throws -> Int64? {
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(
            db,
            "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = ? LIMIT 1;",
            -1,
            &stmt,
            nil
        )
        guard status == SQLITE_OK else {
            throw DatabaseError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        _ = name.withCString { ptr in
            // `SQLITE_TRANSIENT` so SQLite copies the bytes — the C
            // string only lives for the closure scope.
            sqlite3_bind_text(stmt, 1, ptr, -1, sqliteTransient)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let handle else {
            throw DatabaseError.prepareFailed(message: "database closed")
        }
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard status == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw DatabaseError.prepareFailed(message: message)
        }
        return stmt
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cstr)
    }

    private func doubleColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    /// Pull a SQLite BLOB column into a Swift `Data`. Returns `nil` on
    /// NULL columns or zero-length blobs (a zero-length blob is
    /// indistinguishable from a body we couldn't decode and offers no
    /// value to the consumer).
    private func blobColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let length = sqlite3_column_bytes(stmt, index)
        guard length > 0, let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: ptr, count: Int(length))
    }

    /// Convert a Core Data Apple-epoch seconds value to a Foundation
    /// `Date`. Core Data writes these as `REAL` (Double seconds since
    /// 2001-01-01 UTC), distinct from `chat.db`'s nanosecond integer
    /// shape — see `IMessageDatabase.date(fromAppleNanoseconds:)`.
    static func date(fromAppleSeconds seconds: Double) -> Date {
        appleEpoch.addingTimeInterval(seconds)
    }

    /// `SQLITE_TRANSIENT` is a macro Apple's SQLite headers define as
    /// `((sqlite3_destructor_type)-1)`. The macro doesn't survive the
    /// Swift importer, so we recreate it by bit-casting `-1`.
    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}

/// Wire-friendly snapshot of a single note row. The source turns this
/// into a `SyncEnvelope`. Sendable for cross-actor hand-off out of the
/// detached read task.
///
/// `bodyBlob` is the raw `ZICNOTEDATA.ZDATA` value — a gzipped
/// `NoteStoreProto` Protocol Buffer. The source feeds it through
/// `NotesBodyDecoder` to recover the plain-text body; failures degrade
/// gracefully to a `nil` body so the rest of the note still ships.
struct RawNote: Sendable, Equatable {
    let rowID: Int64
    let guid: String
    let title: String?
    let snippet: String?
    let createdAt: Date?
    let modifiedAt: Date?
    let folderRowID: Int64?
    let isPinned: Bool
    let bodyBlob: Data?
}
