import Foundation
import SQLite3

/// Builds tiny SQLite fixtures that mirror the subset of each browser's
/// history schema our readers touch.
enum BrowserHistoryFixture {
    // MARK: - Chromium

    struct ChromiumRow {
        let url: String
        let title: String?
        let visitCount: Int
        let typedCount: Int
        /// Microseconds since 1601-01-01 UTC, matching Chromium's
        /// WebKit `last_visit_time` shape.
        let lastVisitMicroseconds: Int64
    }

    static func buildChromium(at url: URL, rows: [ChromiumRow] = defaultChromiumRows) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "BrowserHistoryFixture", code: 1, userInfo: nil)
        }
        defer { sqlite3_close(db) }

        try exec(db, """
            CREATE TABLE urls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url LONGVARCHAR,
                title LONGVARCHAR,
                visit_count INTEGER DEFAULT 0 NOT NULL,
                typed_count INTEGER DEFAULT 0 NOT NULL,
                last_visit_time INTEGER NOT NULL,
                hidden INTEGER DEFAULT 0 NOT NULL
            );
            """)

        let sql = """
            INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time)
            VALUES (?, ?, ?, ?, ?);
            """
        for row in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "BrowserHistoryFixture",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, row.url, -1, sqliteTransient)
            if let title = row.title {
                sqlite3_bind_text(stmt, 2, title, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_int(stmt, 3, Int32(row.visitCount))
            sqlite3_bind_int(stmt, 4, Int32(row.typedCount))
            sqlite3_bind_int64(stmt, 5, row.lastVisitMicroseconds)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw NSError(
                    domain: "BrowserHistoryFixture",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
        }
    }

    static let defaultChromiumRows: [ChromiumRow] = [
        ChromiumRow(
            url: "https://techmeme.com/article-1",
            title: "Techmeme: AI roundup",
            visitCount: 3,
            typedCount: 0,
            lastVisitMicroseconds: webkit(seconds: 800_000_000)
        ),
        ChromiumRow(
            url: "https://news.ycombinator.com/item?id=42",
            title: "Show HN: Maraithon",
            visitCount: 1,
            typedCount: 0,
            lastVisitMicroseconds: webkit(seconds: 800_000_100)
        ),
        ChromiumRow(
            url: "https://example.com/typed",
            title: "Typed page",
            visitCount: 2,
            typedCount: 1,
            lastVisitMicroseconds: webkit(seconds: 800_000_200)
        )
    ]

    /// Seconds since 2001-01-01 UTC, converted to the WebKit
    /// microseconds-since-1601 timestamps Chromium uses. Picking 2001 as
    /// the input axis just keeps the tests easy to read against Notes /
    /// Safari fixtures that use Apple epoch.
    static func webkit(seconds: Double) -> Int64 {
        // Seconds 2001-01-01 -> 1601-01-01: 12_622_780_800 (978_307_200 unix + 11_644_473_600).
        let secondsSince1601 = seconds + 978_307_200 + 11_644_473_600
        return Int64(secondsSince1601 * 1_000_000)
    }

    // MARK: - Safari

    struct SafariRow {
        let url: String
        let domain: String?
        let visitCount: Int
        let title: String?
        /// Apple-epoch seconds since 2001-01-01 UTC.
        let visitTimeSeconds: Double
    }

    static func buildSafari(at url: URL, rows: [SafariRow] = defaultSafariRows) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "BrowserHistoryFixture", code: 1, userInfo: nil)
        }
        defer { sqlite3_close(db) }

        try exec(db, """
            CREATE TABLE history_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                domain_expansion TEXT,
                visit_count INTEGER NOT NULL DEFAULT 0
            );
            """)
        try exec(db, """
            CREATE TABLE history_visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                history_item INTEGER NOT NULL,
                visit_time REAL NOT NULL,
                title TEXT,
                FOREIGN KEY(history_item) REFERENCES history_items(id)
            );
            """)

        for row in rows {
            try insertSafariRow(db, row)
        }
    }

    static let defaultSafariRows: [SafariRow] = [
        SafariRow(
            url: "https://blog.example.org/post",
            domain: "blog.example.org",
            visitCount: 1,
            title: "Example blog post",
            visitTimeSeconds: 800_000_500
        ),
        SafariRow(
            url: "https://news.ycombinator.com/item?id=99",
            domain: "news.ycombinator.com",
            visitCount: 2,
            title: "Another HN thread",
            visitTimeSeconds: 800_000_600
        )
    ]

    private static func insertSafariRow(_ db: OpaquePointer, _ row: SafariRow) throws {
        let itemSQL = "INSERT INTO history_items (url, domain_expansion, visit_count) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, itemSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "BrowserHistoryFixture",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, row.url, -1, sqliteTransient)
        if let d = row.domain {
            sqlite3_bind_text(stmt, 2, d, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, Int32(row.visitCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "BrowserHistoryFixture",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        let itemID = sqlite3_last_insert_rowid(db)

        let visitSQL = "INSERT INTO history_visits (history_item, visit_time, title) VALUES (?, ?, ?);"
        var vstmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, visitSQL, -1, &vstmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "BrowserHistoryFixture",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(vstmt) }
        sqlite3_bind_int64(vstmt, 1, itemID)
        sqlite3_bind_double(vstmt, 2, row.visitTimeSeconds)
        if let t = row.title {
            sqlite3_bind_text(vstmt, 3, t, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(vstmt, 3)
        }
        guard sqlite3_step(vstmt) == SQLITE_DONE else {
            throw NSError(
                domain: "BrowserHistoryFixture",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
    }

    // MARK: - Helpers

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &err)
        if status != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(
                domain: "BrowserHistoryFixture",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}
