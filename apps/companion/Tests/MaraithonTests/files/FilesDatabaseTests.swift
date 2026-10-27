import XCTest
@testable import Maraithon

final class FilesDatabaseTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-database-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFilesModifiedAfterReturnsEverythingOnEmptyCursor() throws {
        try writeFile(at: "a.md", body: "first")
        try writeFile(at: "b.md", body: "second")

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let database = FilesDatabase(scanner: scanner)
        let results = try database.filesModifiedAfter(cursor: [:])
        let names = results.map(\.filename).sorted()
        XCTAssertEqual(names, ["a.md", "b.md"])
    }

    func testFilesModifiedAfterRespectsCursor() throws {
        try writeFile(at: "a.md", body: "first")

        let scanner = FilesScanner(roots: [tempRoot], limit: 50)
        let database = FilesDatabase(scanner: scanner)

        let initial = try database.filesModifiedAfter(cursor: [:])
        XCTAssertEqual(initial.count, 1)

        let pinned: [String: Date] = [initial[0].localId: initial[0].modifiedAt]
        let second = try database.filesModifiedAfter(cursor: pinned)
        XCTAssertEqual(second.count, 0, "cursor at file's mtime suppresses the row")
    }

    private func writeFile(at relativePath: String, body: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
