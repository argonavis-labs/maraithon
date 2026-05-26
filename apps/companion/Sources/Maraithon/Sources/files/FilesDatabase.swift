import Foundation

/// Thin wrapper that pairs a `FilesScanner` with a `FilesCursor` so
/// callers (mainly `FilesSource`) get a one-shot "what's new since
/// the last push?" interface without juggling both pieces.
///
/// The spec leaves room for FSEvents-driven updates, but a 5-minute
/// poll cadence comfortably covers the user workflow (files change
/// far less often than iMessages) and avoids the complexity of an
/// FSEvents stream sitting on the main actor. We can layer FSEvents
/// underneath this surface later without changing the source's
/// caller signature.
struct FilesDatabase: Sendable {
    let scanner: FilesScanner

    init(scanner: FilesScanner = FilesScanner()) {
        self.scanner = scanner
    }

    /// Scan every configured root and return only files whose
    /// `modified_at` advanced past the cursor's recorded mtime for
    /// that path (or that had no cursor entry). Results are
    /// newest-modified first and capped at the scanner's `limit`.
    func filesModifiedAfter(cursor: [String: Date]) throws -> [RawFile] {
        try scanner.scan(cursor: cursor)
    }
}
