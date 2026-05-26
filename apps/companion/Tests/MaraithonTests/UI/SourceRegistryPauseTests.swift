import XCTest
@testable import Maraithon

/// Tests the per-source pause / resume / sync routing added so detail
/// panes can drive a single source without disturbing the others.
@MainActor
final class SourceRegistryPauseTests: XCTestCase {
    func testPauseRoutesToTheRightSource() {
        let log = EventLog()
        let registry = SourceRegistry(eventLog: log)
        let a = FakeSource(id: "a", displayName: "A", symbol: "a.circle")
        let b = FakeSource(id: "b", displayName: "B", symbol: "b.circle")
        registry.register(a)
        registry.register(b)

        registry.pause(id: "a")
        XCTAssertEqual(a.pauseCount, 1)
        XCTAssertEqual(b.pauseCount, 0)
        XCTAssertEqual(a.statusPublisher.state, .paused)
    }

    func testResumeRoutesToTheRightSource() {
        let log = EventLog()
        let registry = SourceRegistry(eventLog: log)
        let a = FakeSource(id: "a", displayName: "A", symbol: "a.circle")
        registry.register(a)

        registry.pause(id: "a")
        registry.resume(id: "a")
        XCTAssertEqual(a.startCount, 1)
    }

    func testSyncNowForOneSourceLeavesOthersAlone() async {
        let log = EventLog()
        let registry = SourceRegistry(eventLog: log)
        let a = FakeSource(id: "a", displayName: "A", symbol: "a.circle")
        let b = FakeSource(id: "b", displayName: "B", symbol: "b.circle")
        registry.register(a)
        registry.register(b)

        registry.syncNow(id: "a")
        // Let the spawned Task run.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(a.syncCount, 1)
        XCTAssertEqual(b.syncCount, 0)
    }

    func testUnknownIDsNoOpAndDoNotCrash() {
        let log = EventLog()
        let registry = SourceRegistry(eventLog: log)
        registry.pause(id: "ghost")
        registry.resume(id: "ghost")
        registry.syncNow(id: "ghost")
        registry.resetCursor(id: "ghost")
        // Reaching this assertion means none of the above trapped.
        XCTAssertTrue(true)
    }

    func testResetCursorRoutesToTheRightSource() {
        let log = EventLog()
        let registry = SourceRegistry(eventLog: log)
        let a = FakeSource(id: "a", displayName: "A", symbol: "a.circle")
        let b = FakeSource(id: "b", displayName: "B", symbol: "b.circle")
        registry.register(a)
        registry.register(b)

        registry.resetCursor(id: "a")
        XCTAssertEqual(a.clearCount, 1)
        XCTAssertEqual(b.clearCount, 0)
    }
}

@MainActor
final class FakeSource: SourceProtocol {
    let id: String
    let displayName: String
    let symbol: String
    let statusPublisher: SourceStatusPublisher

    private(set) var pauseCount = 0
    private(set) var startCount = 0
    private(set) var syncCount = 0
    private(set) var clearCount = 0

    init(id: String, displayName: String, symbol: String) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
        self.statusPublisher = SourceStatusPublisher(state: .connected)
    }

    func start() {
        startCount += 1
        statusPublisher.update(state: .connected)
    }

    func pause() {
        pauseCount += 1
        statusPublisher.update(state: .paused)
    }

    func syncNow() async throws {
        syncCount += 1
    }

    func clearLocalState() {
        clearCount += 1
    }
}
