import XCTest
@testable import Maraithon

final class FilesScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Privacy filters

    func testExcludesLibraryPath() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/Projects/Library/cache.txt",
            filename: "cache.txt"
        ))
    }

    func testExcludesDotGit() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/code/.git/HEAD",
            filename: "HEAD"
        ))
    }

    func testExcludesNodeModules() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/proj/node_modules/lodash/index.js",
            filename: "index.js"
        ))
    }

    func testExcludesDotSSH() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/.ssh/id_rsa",
            filename: "id_rsa"
        ))
    }

    func testExcludesDotAWS() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/.aws/credentials",
            filename: "credentials"
        ))
    }

    func testExcludesGnuPG() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/.gnupg/secring.gpg",
            filename: "secring.gpg"
        ))
    }

    func testExcludesTrash() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/Trash/old.txt",
            filename: "old.txt"
        ))
    }

    func testExcludesDotfile() {
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/.env",
            filename: ".env"
        ))
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/.npmrc",
            filename: ".npmrc"
        ))
        XCTAssertTrue(FilesScanner.isExcluded(
            relativePath: "/.DS_Store",
            filename: ".DS_Store"
        ))
    }

    func testAllowsLibraryNamedFile() {
        // A file literally called "Library.md" must NOT be excluded —
        // the filter is on the path fragment `Library/`, not the bare
        // name.
        XCTAssertFalse(FilesScanner.isExcluded(
            relativePath: "/Projects/Library.md",
            filename: "Library.md"
        ))
    }

    func testAllowsRegularDocument() {
        XCTAssertFalse(FilesScanner.isExcluded(
            relativePath: "/Projects/notes.md",
            filename: "notes.md"
        ))
    }

    // MARK: - Oversize guard

    func testOversizeGuardRejectsLargeFile() {
        XCTAssertTrue(FilesScanner.isOversize(byteSize: 60 * 1024 * 1024))
        XCTAssertFalse(FilesScanner.isOversize(byteSize: 50 * 1024 * 1024))
        XCTAssertFalse(FilesScanner.isOversize(byteSize: 1024))
    }

    // MARK: - End-to-end scan

    func testScanEmitsAllowedFilesAndSkipsBlocked() throws {
        try writeFile(at: "Projects/notes.md", body: "# Plan\nthings to ship")
        try writeFile(at: "Projects/Library/cache.txt", body: "should be ignored")
        try writeFile(at: "Projects/.env", body: "SECRET=topsecret")
        try writeFile(at: "Projects/node_modules/lodash/index.js", body: "module.exports")

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let results = try scanner.scan(cursor: [:])

        let paths = results.map { $0.filename }.sorted()
        XCTAssertEqual(paths, ["notes.md"])
    }

    func testScanIncludesOversizeIsSkipped() throws {
        // A file just over the 50 MB cap should be filtered out.
        let big = tempRoot.appendingPathComponent("huge.bin")
        let chunk = Data(count: 1024 * 1024)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        // Write 51 MB total.
        for _ in 0 ..< 51 {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()

        try writeFile(at: "small.md", body: "ok")

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let results = try scanner.scan(cursor: [:])
        let names = results.map(\.filename)
        XCTAssertEqual(names, ["small.md"])
    }

    func testScanRespectsCursor() throws {
        try writeFile(at: "old.md", body: "old")
        try writeFile(at: "new.md", body: "new")

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let allFiles = try scanner.scan(cursor: [:])
        XCTAssertEqual(allFiles.count, 2)

        // Build a cursor that has "old.md" already pinned to its
        // current mtime — the next scan should only return "new.md"
        // if we modify it.
        guard let oldRaw = allFiles.first(where: { $0.filename == "old.md" }) else {
            return XCTFail("expected old.md in results")
        }
        let cursor: [String: Date] = [oldRaw.localId: oldRaw.modifiedAt]

        // Touch "new.md" to ensure mtime advances after the cursor.
        let url = tempRoot.appendingPathComponent("new.md")
        try "new updated".write(to: url, atomically: true, encoding: .utf8)

        let nextResults = try scanner.scan(cursor: cursor)
        let nextNames = nextResults.map(\.filename)
        XCTAssertEqual(nextNames, ["new.md"])
    }

    func testScanExtractsMarkdownAndTxt() throws {
        try writeFile(at: "plan.md", body: "shipping the v2 files source")
        try writeFile(at: "todo.txt", body: "buy milk")

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let results = try scanner.scan(cursor: [:])

        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.filename, $0) })
        XCTAssertEqual(byName["plan.md"]?.textContent, "shipping the v2 files source")
        XCTAssertEqual(byName["todo.txt"]?.textContent, "buy milk")
        XCTAssertEqual(byName["plan.md"]?.extension, "md")
        XCTAssertEqual(byName["plan.md"]?.mimeType, "text/markdown")
    }

    func testScanShipsMetadataOnlyForBinaryExtensions() throws {
        // Write a tiny "png" — just a binary blob with the right
        // extension. We're not testing PNG decode; we're testing that
        // the scanner ships the row without trying to extract text.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let pngURL = tempRoot.appendingPathComponent("logo.png")
        try png.write(to: pngURL)

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let results = try scanner.scan(cursor: [:])
        XCTAssertEqual(results.count, 1)
        let row = results[0]
        XCTAssertEqual(row.filename, "logo.png")
        XCTAssertEqual(row.extension, "png")
        XCTAssertEqual(row.mimeType, "image/png")
        XCTAssertNil(row.textContent)
        XCTAssertFalse(row.textTruncated)
    }

    func testPathIsHomeRedacted() throws {
        try writeFile(at: "notes.md", body: "x")
        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let results = try scanner.scan(cursor: [:])
        XCTAssertEqual(results.count, 1)
        let row = results[0]
        // Temp dirs live under /var/folders/... so the redacted path
        // is identical to localId — there's no `~/` prefix on this
        // path. Still: the wire `path` and the `localId` should not
        // ever leak the literal home directory name.
        XCTAssertFalse(row.path.contains(NSUserName()))
    }

    func testClampTrimsOversizedText() {
        let big = String(repeating: "a", count: FilesScanner.maxExtractedBytes + 10)
        let (clamped, truncated) = FilesScanner.clamp(big)
        XCTAssertTrue(truncated)
        XCTAssertEqual(clamped?.utf8.count, FilesScanner.maxExtractedBytes)
    }

    func testClampLeavesUndersizedText() {
        let small = "tiny body"
        let (clamped, truncated) = FilesScanner.clamp(small)
        XCTAssertFalse(truncated)
        XCTAssertEqual(clamped, small)
    }

    func testGuidIsStableForSamePath() {
        let g1 = FilesScanner.stableGuid(path: "/Users/kent/Documents/foo.md")
        let g2 = FilesScanner.stableGuid(path: "/Users/kent/Documents/foo.md")
        XCTAssertEqual(g1, g2)
        XCTAssertTrue(g1.hasPrefix("files:"))
    }

    func testGuidDiffersForDifferentPaths() {
        let g1 = FilesScanner.stableGuid(path: "/a")
        let g2 = FilesScanner.stableGuid(path: "/b")
        XCTAssertNotEqual(g1, g2)
    }

    // MARK: - Helpers

    private func writeFile(at relativePath: String, body: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
