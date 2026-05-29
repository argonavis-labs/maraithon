import XCTest
@testable import Maraithon

final class FullDiskAccessProbeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fda-probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    func testGrantedWhenAnyProtectedStoreIsReadable() throws {
        let missingMessages = tempDir.appendingPathComponent("Messages/chat.db")
        let notesStore = tempDir.appendingPathComponent("NoteStore.sqlite")
        try Data("ok".utf8).write(to: notesStore)

        XCTAssertTrue(
            FullDiskAccessProbe.isGranted(candidateURLs: [missingMessages, notesStore])
        )
    }

    func testNotGrantedWhenCandidatesAreMissing() {
        let missingMessages = tempDir.appendingPathComponent("Messages/chat.db")
        let missingNotes = tempDir.appendingPathComponent("NoteStore.sqlite")

        XCTAssertFalse(
            FullDiskAccessProbe.isGranted(candidateURLs: [missingMessages, missingNotes])
        )
    }

    func testDefaultCandidatesCoverAllFullDiskAccessSources() {
        let paths = FullDiskAccessProbe.protectedDatabaseURLs.map(\.path)

        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Messages/chat.db") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Application Support/com.apple.voicememos/Recordings/CloudRecordings.db") })
    }
}
