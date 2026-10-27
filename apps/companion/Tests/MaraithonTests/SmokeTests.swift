import XCTest
@testable import Maraithon

final class SmokeTests: XCTestCase {
    @MainActor
    func testEventLogAppendsEntries() {
        let log = EventLog(capacity: 16)
        log.info("hello", source: .system)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.message, "hello")
    }

    @MainActor
    func testEventLogRingBufferEvictsOldest() {
        let log = EventLog(capacity: 3)
        log.info("a", source: .system)
        log.info("b", source: .system)
        log.info("c", source: .system)
        log.info("d", source: .system)
        XCTAssertEqual(log.entries.map(\.message), ["b", "c", "d"])
    }

    @MainActor
    func testBlocklistCanonicalisesEmail() {
        let list = Blocklist()
        list.add("Person@Example.COM")
        XCTAssertTrue(list.contains("person@example.com"))
    }
}
