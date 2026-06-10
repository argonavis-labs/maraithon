import AppKit
import CryptoKit
import Foundation
import PDFKit

/// Walks the user's `~/Documents`, `~/Desktop`, and `~/Downloads`
/// directories, surfacing one `RawFile` per file that passes the
/// privacy filters. Extraction of plain text is best-effort: the
/// scanner ships metadata for every file it accepts, and additionally
/// attempts text extraction for PDFs, Markdown, .txt, .rtf, .rtfd,
/// .docx, and .pages files.
///
/// Privacy rules applied to every path before emission:
///
///   * Skip any path component containing `Library/`, `.git/`,
///     `node_modules/`, `.ssh/`, `.aws/`, `.gnupg/`, or `Trash/`.
///   * Skip dotfiles — anything whose filename starts with `.` (e.g.
///     `.env`, `.npmrc`, `.kube/`, `.DS_Store`).
///   * Skip files larger than 50 MB (raw size); we don't read or hash
///     them.
///
/// The scanner is intentionally synchronous; the source runs it inside
/// a detached `Task` so the main actor never blocks on filesystem I/O.
struct FilesScanner: Sendable {
    /// Per-record raw-byte ceiling. Anything larger never even touches
    /// the extraction pipeline.
    static let maxRawBytes: Int64 = 50 * 1024 * 1024

    /// Cap on the extracted text we attach to a `RawFile`. Matches the
    /// server's 200 KB hard cap; the server still defends in depth
    /// because clients can lie about lengths, but trimming here saves
    /// gzip bytes on the wire and base64 inflation along the way.
    static let maxExtractedBytes: Int = 200 * 1024

    /// Roots injected by tests; nil means "follow the user's folder
    /// settings live" so edits apply on the next cycle without a restart.
    private let injectedRoots: [URL]?

    /// Filesystem roots scanned for files. Default: the user's configured
    /// folders (`FilesFolderSettings`), falling back to `~/Documents`,
    /// `~/Desktop`, `~/Downloads`. Tests inject synthetic roots.
    var roots: [URL] {
        injectedRoots ?? FilesFolderSettings.effectiveRoots()
    }

    /// Maximum number of files emitted per scan call. The source
    /// passes this through from its batch-limit configuration so the
    /// cursor only advances over rows the server has accepted.
    let limit: Int

    /// Injection point so tests can pin `now` for deterministic
    /// "modified since" comparisons.
    let clock: @Sendable () -> Date

    init(
        roots: [URL]? = nil,
        limit: Int = 200,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.injectedRoots = roots
        self.limit = limit
        self.clock = clock
    }

    /// Path components that immediately disqualify a candidate file.
    /// Matched as substrings on the *relative* path inside a root, so
    /// `~/Documents/Library/foo` is excluded but a literal file named
    /// `Library.md` is not.
    static let blockedPathFragments: [String] = [
        "Library/",
        ".git/",
        "node_modules/",
        ".ssh/",
        ".aws/",
        ".gnupg/",
        "Trash/"
    ]

    /// File extensions we attempt text extraction for. Anything else
    /// ships as metadata-only (still appears in `files_list_recent`
    /// and `files_search` on filename, but `text_content` is nil).
    static let extractableExtensions: Set<String> = [
        "pdf", "md", "txt", "rtf", "rtfd", "docx", "pages"
    ]

    /// Default roots — the user's three primary working folders. The
    /// app sandbox is disabled so no entitlements are required to
    /// read these. (Per the v2 spec: app sandbox = off; reading
    /// outside the sandbox boundary is fine.)
    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true)
        ]
    }

    /// Walk every configured root and return up to `limit` files whose
    /// `modified_at` advanced past the cursor's recorded mtime for
    /// that path (or that have no cursor entry yet).
    ///
    /// Returns deterministically ordered results: newest-modified
    /// first. The source uses that ordering when it decides which
    /// subset to ship in a single batch.
    func scan(cursor: [String: Date]) throws -> [RawFile] {
        var collected: [RawFile] = []
        for root in roots {
            try scan(
                root: root,
                cursor: cursor,
                into: &collected
            )
        }
        collected.sort { $0.modifiedAt > $1.modifiedAt }
        if collected.count > limit {
            collected = Array(collected.prefix(limit))
        }
        return collected
    }

    // MARK: - Privacy filters

    /// Returns true when a (root-relative) path should be skipped.
    /// Exposed for `FilesScannerTests` so the policy is testable in
    /// isolation without spinning up a full FS fixture.
    static func isExcluded(relativePath: String, filename: String) -> Bool {
        if filename.hasPrefix(".") { return true }
        for blocked in blockedPathFragments {
            if relativePath.contains(blocked) {
                return true
            }
        }
        return false
    }

    /// Returns true when a file's raw byte size disqualifies it from
    /// emission entirely. Public for the same reason as `isExcluded`.
    static func isOversize(byteSize: Int64) -> Bool {
        byteSize > maxRawBytes
    }

    // MARK: - Implementation

    private func scan(
        root: URL,
        cursor: [String: Date],
        into collected: inout [RawFile]
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .typeIdentifierKey
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }

        // Canonicalise the root so symlink-resolved enumerator URLs
        // (`/private/var/...`) still match the prefix when the caller
        // passed an unresolved root (`/var/...`).
        let rootPath = root.resolvingSymlinksInPath().path

        for case let url as URL in enumerator {
            let resolvedPath = url.resolvingSymlinksInPath().path
            let relativePath: String
            if resolvedPath.hasPrefix(rootPath) {
                relativePath = String(resolvedPath.dropFirst(rootPath.count))
            } else {
                relativePath = url.lastPathComponent
            }

            let filename = url.lastPathComponent
            if Self.isExcluded(relativePath: relativePath, filename: filename) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let resourceValues: URLResourceValues
            do {
                resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
            } catch {
                continue
            }

            if resourceValues.isRegularFile != true {
                // `.pages` and `.rtfd` are bundles macOS reports as
                // packages, but `.skipsPackageDescendants` already
                // prevents recursing into them — so we still see the
                // bundle root itself and can extract from it.
                if isExtractableBundle(url: url) {
                    if let raw = try? buildRawFile(
                        url: url,
                        resourceValues: resourceValues,
                        rootPath: rootPath,
                        cursor: cursor,
                        isBundle: true
                    ) {
                        collected.append(raw)
                    }
                }
                continue
            }

            let byteSize = Int64(resourceValues.fileSize ?? 0)
            if Self.isOversize(byteSize: byteSize) {
                continue
            }

            if let raw = try? buildRawFile(
                url: url,
                resourceValues: resourceValues,
                rootPath: rootPath,
                cursor: cursor,
                isBundle: false
            ) {
                collected.append(raw)
            }
        }
    }

    private func isExtractableBundle(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pages" || ext == "rtfd"
    }

    private func buildRawFile(
        url: URL,
        resourceValues: URLResourceValues,
        rootPath: String,
        cursor: [String: Date],
        isBundle: Bool
    ) throws -> RawFile? {
        let modifiedAt = resourceValues.contentModificationDate
            ?? resourceValues.creationDate
            ?? clock()
        let createdAt = resourceValues.creationDate ?? modifiedAt
        let absolutePath = url.path
        let redactedPath = Self.redactHome(absolutePath)

        if let lastSeen = cursor[absolutePath],
           lastSeen.timeIntervalSince(modifiedAt) > -0.001
        {
            // Within 1 ms of the recorded mtime — treat as
            // unchanged. The ISO-8601 round-trip used by
            // `FilesCursor` can lose sub-millisecond precision, so a
            // strict `>=` check would re-emit every file on every
            // cycle.
            return nil
        }

        let filename = url.lastPathComponent
        let extLower = url.pathExtension.lowercased()
        let mime = Self.mimeType(forExtension: extLower)
        // Approximate byte size for bundles by summing children; the
        // exact value isn't load-bearing — the server only uses it for
        // display.
        let byteSize: Int64
        if isBundle {
            byteSize = Self.bundleByteSize(url: url)
        } else {
            byteSize = Int64(resourceValues.fileSize ?? 0)
        }

        let guid = Self.stableGuid(path: absolutePath)

        let textContent: String? = Self.extractableExtensions.contains(extLower)
            ? Self.extractText(from: url, extension: extLower)
            : nil

        let (clampedText, truncated) = Self.clamp(textContent)

        return RawFile(
            guid: guid,
            path: redactedPath,
            localId: absolutePath,
            filename: filename,
            extension: extLower.isEmpty ? nil : extLower,
            mimeType: mime,
            byteSize: byteSize,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            textContent: clampedText,
            textTruncated: truncated
        )
    }

    // MARK: - Helpers

    static func redactHome(_ absolutePath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if absolutePath.hasPrefix(home) {
            return "~" + absolutePath.dropFirst(home.count)
        }
        return absolutePath
    }

    /// Stable hash of the absolute path. The companion uses this as
    /// the idempotency key on the server-side unique index, so
    /// renaming a file (new path) deliberately produces a new row —
    /// that's correct for a personal mirror, since the user thinks
    /// about files by their current location.
    static func stableGuid(path: String) -> String {
        "files:" + sha256Hex(path)
    }

    /// Lightweight SHA-256 via CryptoKit. CryptoKit ships in the
    /// base macOS toolchain so the source doesn't pull in any new
    /// dependency for this hash.
    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a best-effort mime type for the given lower-cased
    /// extension. The static map is intentionally narrow — we only
    /// care about the values the assistant might condition on. Falls
    /// back to nil for unknown extensions; the server stores that as
    /// "no mime" rather than guessing.
    static func mimeType(forExtension ext: String) -> String? {
        switch ext {
        case "pdf":  return "application/pdf"
        case "md":   return "text/markdown"
        case "txt":  return "text/plain"
        case "rtf":  return "application/rtf"
        case "rtfd": return "application/vnd.apple.rtfd"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pages": return "application/vnd.apple.pages"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "mov":  return "video/quicktime"
        case "mp4":  return "video/mp4"
        case "zip":  return "application/zip"
        case "csv":  return "text/csv"
        case "html": return "text/html"
        case "json": return "application/json"
        default:     return nil
        }
    }

    /// Sums the file sizes of a bundle's regular descendants. Bundles
    /// (.pages, .rtfd) report a zero size on the bundle URL itself so
    /// we walk into the package to get a sane number for the UI.
    private static func bundleByteSize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Best-effort text extraction. Always returns either the plain
    /// text or nil — never throws to the caller. The mapping is:
    ///
    ///   * `pdf`        — PDFKit, joined pages.
    ///   * `md`, `txt`  — direct UTF-8 read.
    ///   * `rtf`, `rtfd` — `NSAttributedString` (RTF / RTFD doc type).
    ///   * `docx`       — `NSAttributedString` with `.officeOpenXML`.
    ///   * `pages`      — bundles ship a flattened preview in
    ///     `QuickLook/Preview.pdf`; we read that PDF for the text.
    static func extractText(from url: URL, extension ext: String) -> String? {
        switch ext {
        case "pdf":
            return extractPDF(url: url)
        case "md", "txt":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url))
        case "rtf":
            return extractAttributed(url: url, type: .rtf)
        case "rtfd":
            return extractAttributed(url: url, type: .rtfd)
        case "docx":
            return extractDocx(url: url)
        case "pages":
            return extractPages(url: url)
        default:
            return nil
        }
    }

    private static func extractPDF(url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var pieces: [String] = []
        for index in 0 ..< document.pageCount {
            if let page = document.page(at: index), let text = page.string {
                pieces.append(text)
            }
        }
        let combined = pieces.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    private static func extractAttributed(
        url: URL,
        type: NSAttributedString.DocumentType
    ) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type
        ]
        if let attributed = try? NSAttributedString(
            url: url,
            options: options,
            documentAttributes: nil
        ) {
            return attributed.string
        }
        return nil
    }

    private static func extractDocx(url: URL) -> String? {
        // AppKit can decode `.docx` via the OOXML doc type. Fall back
        // to `nil` rather than guessing — the metadata-only row is
        // strictly better than emitting half-decoded XML.
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML
        ]
        if let attributed = try? NSAttributedString(
            url: url,
            options: options,
            documentAttributes: nil
        ) {
            return attributed.string
        }
        return nil
    }

    private static func extractPages(url: URL) -> String? {
        // `.pages` documents embed a flattened QuickLook PDF preview
        // we can hand to PDFKit. Newer Pages versions may also ship
        // `index.xml`; we don't parse that yet — the QuickLook PDF
        // produces near-perfect plain text in practice.
        let preview = url
            .appendingPathComponent("QuickLook", isDirectory: true)
            .appendingPathComponent("Preview.pdf")
        if FileManager.default.fileExists(atPath: preview.path) {
            return extractPDF(url: preview)
        }
        return nil
    }

    /// Trim extracted text to the server-side hard cap so we don't
    /// waste gzip bytes uploading something the server is just going
    /// to drop on the floor. Returns `(text, truncated)`. The clamp
    /// always lands on a valid character boundary by walking back
    /// from the byte cap to the closest `Character` index.
    static func clamp(_ text: String?) -> (String?, Bool) {
        guard let text else { return (nil, false) }
        if text.utf8.count <= maxExtractedBytes {
            return (text, false)
        }
        // Step back from the raw byte cap one character at a time
        // until the resulting prefix fits the cap. The lossy String
        // decode from a UTF-8 byte slice may insert replacement
        // characters; drop trailing ones so we don't ship them.
        var prefix = String(decoding: text.utf8.prefix(maxExtractedBytes), as: UTF8.self)
        while prefix.last == "\u{FFFD}" {
            prefix.removeLast()
        }
        return (prefix, true)
    }
}

/// One file row built by the scanner. Holds enough state for the
/// source to (a) build a `FilePayload`, (b) advance the cursor on
/// `modified_at`, and (c) log redacted progress.
struct RawFile: Sendable, Equatable {
    let guid: String
    /// Home-redacted path used as the wire `path`. Indexed for
    /// substring filters on the server.
    let path: String
    /// Absolute local path. Lives on `localId` and inside the cursor;
    /// never appears in the wire `path` field.
    let localId: String
    let filename: String
    let `extension`: String?
    let mimeType: String?
    let byteSize: Int64
    let createdAt: Date
    let modifiedAt: Date
    /// Trimmed-to-cap plain text, or `nil` for metadata-only rows.
    let textContent: String?
    /// `true` when extraction yielded more than `maxExtractedBytes`
    /// of UTF-8 and we dropped the tail.
    let textTruncated: Bool
}
