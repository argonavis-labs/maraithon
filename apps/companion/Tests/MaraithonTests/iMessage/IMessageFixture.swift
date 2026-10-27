import Foundation
import SQLite3

/// Builds a tiny but realistic SQLite database that mirrors the subset
/// of Apple's `chat.db` schema the iMessage source touches. Tests use
/// this to exercise the source end-to-end without depending on the
/// host's real Messages database.
///
/// The fixture intentionally creates only the columns the source reads.
/// Extending the source to consume more columns means extending the
/// fixture too — that's a feature, not a bug.
enum IMessageFixture {
    struct Row {
        let guid: String
        let text: String?
        let attributedBody: Data?
        let isFromMe: Bool
        let service: String
        let dateAppleNs: Int64
        let cacheHasAttachments: Bool
        let senderHandleID: Int64?
        let chatRowID: Int64?
    }

    /// Builds a `chat.db`-shaped database at `url` with a handful of
    /// canned messages including:
    ///   * a 1:1 thread with a phone-number handle
    ///   * a group chat with two participants
    ///   * a mix of `text`-populated and `attributedBody`-populated rows
    ///   * one message authored by the local user (`is_from_me = 1`)
    ///   * one message from a handle we'll later add to the blocklist
    static func build(at url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openStatus = sqlite3_open_v2(url.path, &db, flags, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "IMessageFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }

        try exec(db, schemaSQL)

        // Handles: ROWID is implicit autoincrement.
        try exec(db, "INSERT INTO handle (id, service) VALUES ('+14165550199', 'iMessage');")    // 1
        try exec(db, "INSERT INTO handle (id, service) VALUES ('+14165550144', 'iMessage');")    // 2
        try exec(db, "INSERT INTO handle (id, service) VALUES ('blocked@example.com', 'iMessage');") // 3

        // Chats: style 45 = 1:1, 43 = group.
        try exec(db, """
            INSERT INTO chat (guid, display_name, chat_identifier, style)
            VALUES ('iMessage;-;+14165550199', NULL, '+14165550199', 45);
            """)  // 1
        try exec(db, """
            INSERT INTO chat (guid, display_name, chat_identifier, style)
            VALUES ('iMessage;+;groupA', 'Team Group', 'chat12345', 43);
            """)  // 2
        try exec(db, """
            INSERT INTO chat (guid, display_name, chat_identifier, style)
            VALUES ('iMessage;-;blocked@example.com', NULL, 'blocked@example.com', 45);
            """)  // 3

        // Chat <-> handle joins.
        try exec(db, "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);")
        try exec(db, "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 1);")
        try exec(db, "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 2);")
        try exec(db, "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (3, 3);")

        let rows: [Row] = [
            // 1:1 from +14165550199, text column populated.
            Row(
                guid: "MSG-0001",
                text: "Want to grab coffee tomorrow?",
                attributedBody: nil,
                isFromMe: false,
                service: "iMessage",
                dateAppleNs: 779_500_000_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: 1,
                chatRowID: 1
            ),
            // 1:1 reply from me.
            Row(
                guid: "MSG-0002",
                text: "Sure, 9am at Pilot.",
                attributedBody: nil,
                isFromMe: true,
                service: "iMessage",
                dateAppleNs: 779_500_010_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: nil,
                chatRowID: 1
            ),
            // Group message with attributedBody only.
            Row(
                guid: "MSG-0003",
                text: nil,
                attributedBody: try? attributedBodyData("Headed to lunch — anyone?"),
                isFromMe: false,
                service: "iMessage",
                dateAppleNs: 779_500_020_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: 2,
                chatRowID: 2
            ),
            // Blocked sender — should never leave the device.
            Row(
                guid: "MSG-0004",
                text: "Limited-time offer!",
                attributedBody: nil,
                isFromMe: false,
                service: "iMessage",
                dateAppleNs: 779_500_030_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: 3,
                chatRowID: 3
            ),
            // Group message back from +14165550199.
            Row(
                guid: "MSG-0005",
                text: "in 10",
                attributedBody: nil,
                isFromMe: false,
                service: "iMessage",
                dateAppleNs: 779_500_040_000_000_000,
                cacheHasAttachments: false,
                senderHandleID: 1,
                chatRowID: 2
            )
        ]

        for row in rows {
            try insertMessage(db, row)
        }
    }

    static func appendMessage(at url: URL, _ row: Row) throws {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw NSError(
                domain: "IMessageFixture",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: "open failed"]
            )
        }
        defer { sqlite3_close(db) }
        try insertMessage(db, row)
    }

    /// Wraps a plain string into a `NSKeyedArchiver` blob the way
    /// `chat.db` stores `attributedBody`. Tests assert the decoder
    /// recovers the same string.
    static func attributedBodyData(_ string: String) throws -> Data {
        let attributed = NSAttributedString(string: string)
        return try NSKeyedArchiver.archivedData(
            withRootObject: attributed,
            requiringSecureCoding: false
        )
    }

    // MARK: - Internals

    private static func insertMessage(_ db: OpaquePointer, _ row: Row) throws {
        let sql = """
            INSERT INTO message
              (guid, text, attributedBody, date, is_from_me, service,
               handle_id, cache_has_attachments)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "IMessageFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, row.guid, -1, sqliteTransient)
        if let text = row.text {
            sqlite3_bind_text(stmt, 2, text, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let blob = row.attributedBody {
            _ = blob.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(blob.count), sqliteTransient)
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, row.dateAppleNs)
        sqlite3_bind_int(stmt, 5, row.isFromMe ? 1 : 0)
        sqlite3_bind_text(stmt, 6, row.service, -1, sqliteTransient)
        if let handleID = row.senderHandleID {
            sqlite3_bind_int64(stmt, 7, handleID)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int(stmt, 8, row.cacheHasAttachments ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "IMessageFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        if let chatRow = row.chatRowID {
            let messageRowID = sqlite3_last_insert_rowid(db)
            let joinSQL = "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?);"
            var joinStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, joinSQL, -1, &joinStmt, nil) == SQLITE_OK else {
                throw NSError(domain: "IMessageFixture", code: 3, userInfo: nil)
            }
            defer { sqlite3_finalize(joinStmt) }
            sqlite3_bind_int64(joinStmt, 1, chatRow)
            sqlite3_bind_int64(joinStmt, 2, messageRowID)
            guard sqlite3_step(joinStmt) == SQLITE_DONE else {
                throw NSError(domain: "IMessageFixture", code: 4, userInfo: nil)
            }
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &err)
        if status != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(
                domain: "IMessageFixture",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    private static let schemaSQL = """
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL,
            service TEXT NOT NULL
        );
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT NOT NULL,
            display_name TEXT,
            chat_identifier TEXT,
            style INTEGER
        );
        CREATE TABLE chat_handle_join (
            chat_id INTEGER NOT NULL,
            handle_id INTEGER NOT NULL,
            PRIMARY KEY (chat_id, handle_id)
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT NOT NULL,
            text TEXT,
            attributedBody BLOB,
            date INTEGER NOT NULL,
            is_from_me INTEGER NOT NULL DEFAULT 0,
            service TEXT,
            handle_id INTEGER,
            cache_has_attachments INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            PRIMARY KEY (chat_id, message_id)
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
