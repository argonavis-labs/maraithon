import XCTest
@testable import Maraithon

final class SyncQueueTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-queue-tests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private func makeEnvelope(localId: String) -> SyncEnvelope {
        SyncEnvelope(
            source: "imessage",
            localId: localId,
            guid: "guid-\(localId)",
            payload: ["text": AnyCodable("hi")]
        )
    }

    func testEnqueueAndPeekReturnsFIFO() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let q = SyncQueue(storageURL: url)
        try await q.enqueue([makeEnvelope(localId: "1"), makeEnvelope(localId: "2")])

        let head = try await q.peek(limit: 1)
        XCTAssertEqual(head.first?.localId, "1")

        let all = try await q.peek(limit: 10)
        XCTAssertEqual(all.map(\.localId), ["1", "2"])
    }

    func testAcknowledgeRemovesPrefix() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let q = SyncQueue(storageURL: url)
        try await q.enqueue([
            makeEnvelope(localId: "1"),
            makeEnvelope(localId: "2"),
            makeEnvelope(localId: "3")
        ])
        try await q.acknowledge(count: 2)
        let remaining = try await q.peek(limit: 10)
        XCTAssertEqual(remaining.map(\.localId), ["3"])
    }

    func testQueuePersistsAcrossInstances() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let q = SyncQueue(storageURL: url)
            try await q.enqueue([makeEnvelope(localId: "a"), makeEnvelope(localId: "b")])
        }
        let q2 = SyncQueue(storageURL: url)
        let restored = try await q2.peek(limit: 10)
        XCTAssertEqual(restored.map(\.localId), ["a", "b"])
        let n = try await q2.count()
        XCTAssertEqual(n, 2)
    }

    func testClearWipesQueue() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let q = SyncQueue(storageURL: url)
        try await q.enqueue([makeEnvelope(localId: "x")])
        try await q.clear()
        let n = try await q.count()
        XCTAssertEqual(n, 0)
    }

    func testEmptyFileLoadsAsEmpty() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let q = SyncQueue(storageURL: url)
        let n = try await q.count()
        XCTAssertEqual(n, 0)
    }
}
