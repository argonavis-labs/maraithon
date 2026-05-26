import Foundation
import SQLite3

/// Read-only wrapper over `~/Library/Messages/chat.db`. Opens with
/// `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` so Apple's WAL writers
/// never block us and we never block them. The init takes an explicit
/// database URL so tests can hand in a synthetic SQLite file.
///
/// Apple's `message.date` column is "nanoseconds since 2001-01-01 UTC"
/// on modern macOS; conversion to Foundation `Date` happens in this
/// layer so callers never deal with raw Apple epoch math.
final class IMessageDatabase: @unchecked Sendable {
    /// Default location of the user's iMessage store.
    static var defaultDatabaseURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Messages", isDirectory: true)
            .appendingPathComponent("chat.db", isDirectory: false)
    }

    /// Apple's epoch (2001-01-01 UTC), exposed for tests.
    static let appleEpoch: Date = {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private var handle: OpaquePointer?

    init(url: URL = IMessageDatabase.defaultDatabaseURL) throws {
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

    /// Errors surfaced from the SQLite layer. Callers translate these
    /// into `SourceState.error` for the UI.
    enum DatabaseError: Error, Equatable {
        case openFailed(code: Int32, message: String)
        case prepareFailed(message: String)
        case stepFailed(message: String)
    }

    /// Read every message with `ROWID > rowid`, ordered ASC, capped at
    /// `limit`. Retained for tests / legacy callers; the live source
    /// uses `messagesNewerThan` / `messagesOlderThan` (both DESC) to
    /// drive the newest-first cycle.
    func messagesAfter(rowid: Int64, limit: Int = 200) throws -> [RawMessage] {
        try messagesWhere(predicate: "m.ROWID > ?", bound: rowid, ascending: true, limit: limit)
    }

    /// Newer-than walk: rows with `ROWID > rowid` ordered DESC. Used by
    /// the live source to ship today's messages first.
    func messagesNewerThan(rowid: Int64, limit: Int = 200) throws -> [RawMessage] {
        try messagesWhere(predicate: "m.ROWID > ?", bound: rowid, ascending: false, limit: limit)
    }

    /// Older-than walk: rows with `ROWID < rowid` ordered DESC. Used to
    /// backfill historical messages after the newer-than walk is
    /// caught up.
    func messagesOlderThan(rowid: Int64, limit: Int = 200) throws -> [RawMessage] {
        try messagesWhere(predicate: "m.ROWID < ?", bound: rowid, ascending: false, limit: limit)
    }

    private func messagesWhere(
        predicate: String,
        bound: Int64,
        ascending: Bool,
        limit: Int
    ) throws -> [RawMessage] {
        let order = ascending ? "ASC" : "DESC"
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.attributedBody,
                m.date,
                m.is_from_me,
                m.service,
                m.handle_id,
                m.cache_has_attachments,
                cmj.chat_id
            FROM message m
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(predicate)
            ORDER BY m.ROWID \(order)
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, bound)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let guid = stringColumn(stmt, 1) ?? ""
            let text = stringColumn(stmt, 2)
            let attributedBody = blobColumn(stmt, 3)
            let dateNs = sqlite3_column_int64(stmt, 4)
            let isFromMe = sqlite3_column_int(stmt, 5) != 0
            let service = stringColumn(stmt, 6) ?? "iMessage"
            let handleID = sqlite3_column_int64(stmt, 7)
            let hasAttachments = sqlite3_column_int(stmt, 8) != 0
            let chatID: Int64? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(stmt, 9)

            rows.append(
                RawMessage(
                    rowID: rowID,
                    guid: guid,
                    text: text,
                    attributedBody: attributedBody,
                    sentAt: Self.date(fromAppleNanoseconds: dateNs),
                    isFromMe: isFromMe,
                    service: service,
                    handleRowID: handleID == 0 ? nil : handleID,
                    hasAttachments: hasAttachments,
                    chatRowID: chatID
                )
            )
        }
        return rows
    }

    /// Look up a handle's wire identifier (phone or email) by its ROWID.
    func handle(rowid: Int64) throws -> String? {
        let stmt = try prepare("SELECT id FROM handle WHERE ROWID = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return stringColumn(stmt, 0)
        }
        return nil
    }

    /// Resolve the chat a given message belongs to, plus the set of
    /// participating handles. `chatRowID` is the value returned by
    /// `messagesAfter` (i.e. `chat_message_join.chat_id`).
    func chat(rowid: Int64) throws -> ChatInfo? {
        let chatStmt = try prepare("""
            SELECT guid, display_name, chat_identifier, style
            FROM chat
            WHERE ROWID = ?
            LIMIT 1;
            """)
        defer { sqlite3_finalize(chatStmt) }
        sqlite3_bind_int64(chatStmt, 1, rowid)
        guard sqlite3_step(chatStmt) == SQLITE_ROW else { return nil }
        let guid = stringColumn(chatStmt, 0) ?? ""
        let displayName = stringColumn(chatStmt, 1)
        let identifier = stringColumn(chatStmt, 2) ?? ""
        let style = sqlite3_column_int(chatStmt, 3)

        let participantsStmt = try prepare("""
            SELECT h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.ROWID ASC;
            """)
        defer { sqlite3_finalize(participantsStmt) }
        sqlite3_bind_int64(participantsStmt, 1, rowid)
        var handles: [String] = []
        while sqlite3_step(participantsStmt) == SQLITE_ROW {
            if let id = stringColumn(participantsStmt, 0) {
                handles.append(id)
            }
        }

        // Apple uses style 43 for group chats, 45 for 1:1. We translate
        // anything that's not 43 into "im" so a future style code doesn't
        // mis-route a 1:1 thread.
        let chatStyle: ChatStyle = (style == 43) ? .group : .im
        return ChatInfo(
            rowID: rowid,
            guid: guid,
            displayName: displayName,
            identifier: identifier,
            style: chatStyle,
            participantHandles: handles
        )
    }

    // MARK: - Helpers

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

    private func blobColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let bytes = sqlite3_column_blob(stmt, index)
        let length = Int(sqlite3_column_bytes(stmt, index))
        guard let bytes, length > 0 else { return nil }
        return Data(bytes: bytes, count: length)
    }

    static func date(fromAppleNanoseconds ns: Int64) -> Date {
        // Older macOS rows store seconds, not nanoseconds; if the value
        // is small enough to plausibly be a second-count (< 2^32),
        // interpret it as seconds. Newer rows are nanoseconds.
        let seconds: Double
        if ns < Int64(1_000_000_000_000) {
            // < 10^12 → seconds since Apple epoch.
            seconds = Double(ns)
        } else {
            seconds = Double(ns) / 1_000_000_000
        }
        return appleEpoch.addingTimeInterval(seconds)
    }
}

/// Wire-friendly snapshot of a single row from `message`. The source
/// turns this into a `SyncEnvelope`.
struct RawMessage: Sendable {
    let rowID: Int64
    let guid: String
    let text: String?
    let attributedBody: Data?
    let sentAt: Date
    let isFromMe: Bool
    let service: String
    let handleRowID: Int64?
    let hasAttachments: Bool
    let chatRowID: Int64?
}

/// Group + 1:1 chat metadata used to populate the push payload's
/// `chat_handles`, `chat_display_name`, and `chat_style` fields.
struct ChatInfo: Sendable, Equatable {
    let rowID: Int64
    let guid: String
    let displayName: String?
    let identifier: String
    let style: ChatStyle
    let participantHandles: [String]
}

enum ChatStyle: String, Sendable, Equatable {
    case im
    case group
}
