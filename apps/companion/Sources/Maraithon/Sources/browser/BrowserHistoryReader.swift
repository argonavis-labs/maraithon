import Foundation
import SQLite3

/// Identity of a browser whose history we know how to read. Names match
/// what the server's `LocalBrowserHistory` schema expects — keep them
/// lowercase and stable.
enum Browser: String, Codable, CaseIterable, Sendable {
    case chrome
    case safari
    case arc
    case brave

    /// Live database location on disk. `nil` when the browser is not
    /// installed (i.e. the directory doesn't exist for the current user).
    var liveDatabaseURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        switch self {
        case .chrome:
            return chromiumStyleDatabase(
                base: home
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Google", isDirectory: true)
                    .appendingPathComponent("Chrome", isDirectory: true)
            )

        case .arc:
            return chromiumStyleDatabase(
                base: home
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Arc", isDirectory: true)
                    .appendingPathComponent("User Data", isDirectory: true)
            )

        case .brave:
            return chromiumStyleDatabase(
                base: home
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("BraveSoftware", isDirectory: true)
                    .appendingPathComponent("Brave-Browser", isDirectory: true)
            )

        case .safari:
            let url = home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Safari", isDirectory: true)
                .appendingPathComponent("History.db", isDirectory: false)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Pick the most plausible Chromium profile under `base/<profile>/History`.
    /// Tries `Default` first, then falls back to the first profile-shaped
    /// directory containing a `History` file. Returns `nil` if `base`
    /// doesn't exist on disk — the source uses that to decide whether to
    /// register a reader at all.
    private func chromiumStyleDatabase(base: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return nil }

        let defaultURL = base
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("History", isDirectory: false)
        if fm.fileExists(atPath: defaultURL.path) {
            return defaultURL
        }

        // Walk one level deep for `Profile 1`, `Profile 2`, etc. We pick
        // the first one with a `History` file. Multi-profile users can
        // override with a custom URL via the test-only initializer.
        let candidates = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for url in candidates {
            let history = url.appendingPathComponent("History", isDirectory: false)
            if fm.fileExists(atPath: history.path) {
                return history
            }
        }
        return nil
    }
}

/// One visit row as the wire-format expects it. Field shapes match the
/// server's `LocalBrowserHistory.LocalVisit` schema.
struct BrowserVisitRecord: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let browser: String
    let url: String
    let title: String?
    let host: String?
    let visitCount: Int
    let isTypedUrl: Bool
    let lastVisitedAt: String?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case browser
        case url
        case title
        case host
        case visitCount = "visit_count"
        case isTypedUrl = "is_typed_url"
        case lastVisitedAt = "last_visited_at"
    }
}

/// Reads visits from one browser's history database. Each implementation
/// is responsible for the per-browser SQL and timestamp conversions.
///
/// All real implementations are `final class` rather than struct because
/// SQLite handles aren't trivially copyable; the only state held across
/// reads is the temp-file URL of the copied database.
protocol BrowserHistoryReader: AnyObject, Sendable {
    var browser: Browser { get }

    /// Read every visit with a backend-native id greater than `cursor`,
    /// capped at `limit`. The cursor monotonically increases per browser
    /// — Chromium uses `urls.id`, Safari uses `history_items.id`.
    func visits(after cursor: Int64, limit: Int) throws -> [BrowserVisitRecord]
}

/// Read-only SQLite reader that copies the browser's live `History` file
/// to a temp location before opening it. Chromium's `History` is busy
/// while Chrome is running; even though `SQLITE_OPEN_READONLY` lets us
/// open it, WAL-mode locking can intermittently fail. Copying to a temp
/// path means we never contend with the running browser and our reads
/// are consistent.
final class ChromiumHistoryReader: BrowserHistoryReader, @unchecked Sendable {
    let browser: Browser
    private let liveURL: URL
    private let copy: TempDatabaseCopy

    init(browser: Browser, liveURL: URL) throws {
        self.browser = browser
        self.liveURL = liveURL
        self.copy = try TempDatabaseCopy(liveURL: liveURL, prefix: "maraithon-\(browser.rawValue)")
    }

    func visits(after cursor: Int64, limit: Int) throws -> [BrowserVisitRecord] {
        try copy.refresh()

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(copy.tempURL.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw BrowserHistoryReaderError.openFailed(code: status, message: msg)
        }
        defer { sqlite3_close(db) }

        // `urls.last_visit_time` is Chrome's WebKit timestamp:
        // microseconds since 1601-01-01 UTC. Convert at read time.
        let sql = """
            SELECT id, url, title, visit_count, typed_count, last_visit_time
            FROM urls
            WHERE id > ?
            ORDER BY id ASC
            LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserHistoryReaderError.prepareFailed(
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, cursor)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let browserName = browser.rawValue

        var rows: [BrowserVisitRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let urlString = stringColumn(stmt, 1) ?? ""
            let title = stringColumn(stmt, 2)
            let visitCount = Int(sqlite3_column_int(stmt, 3))
            let typedCount = Int(sqlite3_column_int(stmt, 4))
            let lastVisitTime = sqlite3_column_int64(stmt, 5)

            guard !urlString.isEmpty else { continue }

            let host = URL(string: urlString)?.host
            let date = Self.date(fromWebKitMicroseconds: lastVisitTime)

            rows.append(
                BrowserVisitRecord(
                    guid: "\(browserName):\(id)",
                    localId: String(id),
                    browser: browserName,
                    url: urlString,
                    title: title,
                    host: host?.lowercased(),
                    visitCount: max(visitCount, 1),
                    isTypedUrl: typedCount > 0,
                    lastVisitedAt: date.map(iso.string(from:))
                )
            )
        }
        return rows
    }

    /// Convert a Chromium WebKit timestamp (microseconds since
    /// 1601-01-01 UTC) to a Foundation `Date`. Zero or negative values
    /// mean "no visit yet" and return nil so the wire field stays nil.
    static func date(fromWebKitMicroseconds micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        // 11644473600 = seconds between 1601-01-01 and Unix epoch.
        let seconds = Double(micros) / 1_000_000.0 - 11_644_473_600.0
        return Date(timeIntervalSince1970: seconds)
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cstr)
    }
}

/// Safari reader. Safari stores history in
/// `~/Library/Safari/History.db` with `history_items` (id, url, domain,
/// visit_count) and `history_visits` (id, history_item, visit_time,
/// title). `visit_time` is Apple-epoch seconds since 2001-01-01 UTC, the
/// same convention Notes and iMessage use.
final class SafariHistoryReader: BrowserHistoryReader, @unchecked Sendable {
    let browser: Browser = .safari
    private let copy: TempDatabaseCopy

    init(liveURL: URL) throws {
        self.copy = try TempDatabaseCopy(liveURL: liveURL, prefix: "maraithon-safari")
    }

    func visits(after cursor: Int64, limit: Int) throws -> [BrowserVisitRecord] {
        try copy.refresh()

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(copy.tempURL.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw BrowserHistoryReaderError.openFailed(code: status, message: msg)
        }
        defer { sqlite3_close(db) }

        // Pair each history_items row with the most recent visit for it
        // so we can surface a title and a `last_visited_at`. Most users
        // re-visit a URL many times; we want the freshest visit per id.
        let sql = """
            SELECT
                items.id,
                items.url,
                items.domain_expansion,
                items.visit_count,
                (SELECT MAX(history_visits.visit_time)
                   FROM history_visits
                   WHERE history_visits.history_item = items.id),
                (SELECT history_visits.title
                   FROM history_visits
                   WHERE history_visits.history_item = items.id
                   ORDER BY history_visits.visit_time DESC
                   LIMIT 1)
            FROM history_items AS items
            WHERE items.id > ?
            ORDER BY items.id ASC
            LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserHistoryReaderError.prepareFailed(
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, cursor)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var rows: [BrowserVisitRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let urlString = stringColumn(stmt, 1) ?? ""
            let domainExpansion = stringColumn(stmt, 2)
            let visitCount = Int(sqlite3_column_int(stmt, 3))
            let lastVisitTime = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 4)
            let title = stringColumn(stmt, 5)

            guard !urlString.isEmpty else { continue }

            let host = URL(string: urlString)?.host ?? domainExpansion
            let date = lastVisitTime.map { Self.date(fromAppleSeconds: $0) }

            rows.append(
                BrowserVisitRecord(
                    guid: "safari:\(id)",
                    localId: String(id),
                    browser: "safari",
                    url: urlString,
                    title: title,
                    host: host?.lowercased(),
                    visitCount: max(visitCount, 1),
                    // Safari history doesn't expose a typed-vs-link
                    // signal in this schema, so we default to false.
                    isTypedUrl: false,
                    lastVisitedAt: date.map(iso.string(from:))
                )
            )
        }
        return rows
    }

    static let appleEpoch: Date = {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    static func date(fromAppleSeconds seconds: Double) -> Date {
        appleEpoch.addingTimeInterval(seconds)
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cstr)
    }
}

/// Manages a snapshot copy of a live browser-history sqlite file. The
/// snapshot is recreated on each `refresh()` so the reader picks up
/// rows the browser wrote between syncs. Copying once per cycle is
/// cheap (Chrome's `History` is typically <100 MB even after years of
/// use) and avoids the WAL-locking surprises you can get if you try to
/// open the live file directly.
final class TempDatabaseCopy: @unchecked Sendable {
    let liveURL: URL
    let tempURL: URL

    init(liveURL: URL, prefix: String) throws {
        self.liveURL = liveURL
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempURL = dir.appendingPathComponent(liveURL.lastPathComponent, isDirectory: false)
        try copyFiles()
    }

    deinit {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    func refresh() throws {
        try copyFiles()
    }

    private func copyFiles() throws {
        let fm = FileManager.default
        // Replace existing copy atomically — `copyItem` errors if dest
        // exists, and `replaceItem` needs both URLs in the same dir.
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: liveURL, to: tempURL)

        // Also copy the WAL + SHM sidecars when they exist. Without
        // them, recent writes in the live WAL aren't visible through
        // the snapshot.
        for suffix in ["-wal", "-shm"] {
            let liveSide = URL(fileURLWithPath: liveURL.path + suffix)
            let tempSide = URL(fileURLWithPath: tempURL.path + suffix)
            if fm.fileExists(atPath: tempSide.path) {
                try fm.removeItem(at: tempSide)
            }
            if fm.fileExists(atPath: liveSide.path) {
                // Sidecar may vanish between fileExists and copy — that's
                // fine, ignore that specific NSCocoa "no file" race.
                do { try fm.copyItem(at: liveSide, to: tempSide) } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                        continue
                    }
                    throw error
                }
            }
        }
    }
}

enum BrowserHistoryReaderError: Error, Equatable {
    case openFailed(code: Int32, message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)
}
