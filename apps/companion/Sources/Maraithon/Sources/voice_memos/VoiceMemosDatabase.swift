import Foundation
import SQLite3

/// Read-only wrapper over Voice Memos' Core Data SQLite at
/// `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`.
/// (Apple moved the store into a shared group container in macOS Monterey;
/// the older `~/Library/Application Support/com.apple.voicememos/...` path
/// only exists on early Big Sur installs and is checked as a fallback.)
///
/// Apple stores the database alongside the `.m4a` recordings — `ZPATH` is
/// a path relative to the directory containing the database, so this type
/// resolves the audio file by joining the two. File size lookup happens
/// here too so the source doesn't have to know where the audio lives.
///
/// Opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` so the Voice
/// Memos app's writers never block us and we never block them. Init takes
/// an explicit URL so tests can hand in a synthetic SQLite file inside a
/// fixture directory.
///
/// `ZDATE` is "seconds since 2001-01-01 UTC" (Apple's Core Data epoch);
/// conversion to Foundation `Date` happens here so callers never deal with
/// raw Apple epoch math.
final class VoiceMemosDatabase: @unchecked Sendable {
    /// Default location of the user's Voice Memos store. Picks the first
    /// path that actually exists — the modern shared-group-container path
    /// on Monterey+ first, the legacy `Application Support` path second.
    /// Falls back to the modern path even when neither exists so first-run
    /// users (no recordings yet) get a sensible error path instead of a
    /// stale legacy guess.
    static var defaultDatabaseURL: URL {
        let candidates = [sharedContainerDatabaseURL, legacyDatabaseURL]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return sharedContainerDatabaseURL
    }

    /// Monterey+ path: shared group container backing the sandboxed
    /// Voice Memos app.
    static var sharedContainerDatabaseURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent("group.com.apple.VoiceMemos.shared", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("CloudRecordings.db", isDirectory: false)
    }

    /// Legacy path used on early Big Sur installs.
    static var legacyDatabaseURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.apple.voicememos", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("CloudRecordings.db", isDirectory: false)
    }

    /// Apple's Core Data epoch (2001-01-01 UTC), exposed for tests.
    static let appleEpoch: Date = {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    /// Directory the database lives in; relative `ZPATH` values resolve
    /// against this.
    let recordingsDirectory: URL

    private let fileManager: FileManager
    private var handle: OpaquePointer?

    init(
        url: URL = VoiceMemosDatabase.defaultDatabaseURL,
        fileManager: FileManager = .default
    ) throws {
        self.recordingsDirectory = url.deletingLastPathComponent()
        self.fileManager = fileManager
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw DatabaseError.openFailed(code: status, message: message)
        }
        self.handle = db
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// Errors surfaced from the SQLite layer. Callers translate these into
    /// `SourceState.error` for the UI.
    enum DatabaseError: Error, Equatable {
        case openFailed(code: Int32, message: String)
        case prepareFailed(message: String)
    }

    /// Read every recording with `Z_PK > rowid`, ordered ASC, capped at
    /// `limit`. Rows whose backing `.m4a` is missing on disk are skipped
    /// (synced-away or deleted recordings) so the source never pushes
    /// metadata that points at nothing. Returns an empty array when there
    /// is nothing new.
    func recordingsAfter(rowid: Int64, limit: Int = 200) throws -> [RawVoiceMemo] {
        try recordingsWhere(predicate: "Z_PK > ?", bound: rowid, ascending: true, limit: limit)
    }

    func recordingsNewerThan(rowid: Int64, limit: Int = 200) throws -> [RawVoiceMemo] {
        try recordingsWhere(predicate: "Z_PK > ?", bound: rowid, ascending: false, limit: limit)
    }

    func recordingsOlderThan(rowid: Int64, limit: Int = 200) throws -> [RawVoiceMemo] {
        try recordingsWhere(predicate: "Z_PK < ?", bound: rowid, ascending: false, limit: limit)
    }

    private func recordingsWhere(
        predicate: String,
        bound: Int64,
        ascending: Bool,
        limit: Int
    ) throws -> [RawVoiceMemo] {
        let order = ascending ? "ASC" : "DESC"
        let sql = """
            SELECT
                ZCLOUDRECORDING.Z_PK,
                ZCLOUDRECORDING.ZUNIQUEID,
                ZCLOUDRECORDING.ZCUSTOMLABEL,
                ZCLOUDRECORDING.ZDATE,
                ZCLOUDRECORDING.ZDURATION,
                ZCLOUDRECORDING.ZPATH
            FROM ZCLOUDRECORDING
            WHERE ZCLOUDRECORDING.\(predicate)
            ORDER BY ZCLOUDRECORDING.Z_PK \(order)
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, bound)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [RawVoiceMemo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let uniqueID = stringColumn(stmt, 1) ?? ""
            let customLabel = stringColumn(stmt, 2)
            let dateSeconds = sqlite3_column_double(stmt, 3)
            let duration = sqlite3_column_double(stmt, 4)
            let relativePath = stringColumn(stmt, 5)

            let createdAt = Self.appleEpoch.addingTimeInterval(dateSeconds)
            let audioURL = relativePath.map {
                recordingsDirectory.appendingPathComponent($0, isDirectory: false)
            }
            // Skip rows whose .m4a isn't on disk. iCloud-evicted recordings
            // and freshly-deleted rows show up here; pushing metadata for
            // a missing file is worse than dropping it — the server would
            // hold a guid we can never resolve, and the cursor would still
            // advance past it on the next cycle.
            let fileSize: Int64
            if let audioURL,
               let size = audioFileSize(at: audioURL) {
                fileSize = size
            } else {
                continue
            }

            rows.append(
                RawVoiceMemo(
                    rowID: pk,
                    uniqueID: uniqueID,
                    customLabel: customLabel,
                    createdAt: createdAt,
                    durationSeconds: duration,
                    audioURL: audioURL,
                    fileSizeBytes: fileSize
                )
            )
        }
        return rows
    }

    // MARK: - Helpers

    private func audioFileSize(at url: URL) -> Int64? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.int64Value
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
}

/// Wire-friendly snapshot of a single row from `ZCLOUDRECORDING`. The
/// source turns this into a `SyncEnvelope`-shaped payload.
struct RawVoiceMemo: Sendable, Equatable {
    /// `Z_PK` — used as the monotonic cursor key.
    let rowID: Int64
    /// `ZUNIQUEID` — stable UUID-shaped string used as the dedupe `guid`.
    let uniqueID: String
    /// `ZCUSTOMLABEL` — user-set title, may be nil. Source applies a
    /// derived fallback before push.
    let customLabel: String?
    /// `ZDATE`, normalised to a Foundation `Date`.
    let createdAt: Date
    /// `ZDURATION`, seconds.
    let durationSeconds: Double
    /// Resolved `.m4a` location, or `nil` if `ZPATH` was missing.
    let audioURL: URL?
    /// Size of the resolved `.m4a` on disk.
    let fileSizeBytes: Int64
}
