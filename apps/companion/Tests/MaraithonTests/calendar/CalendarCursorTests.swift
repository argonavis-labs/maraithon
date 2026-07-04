import XCTest
@testable import Maraithon

final class CalendarCursorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "com.maraithon.companion.calendar-cursor-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testEmptyOnFirstRun() {
        let cursor = CalendarCursor(defaults: defaults)
        XCTAssertEqual(cursor.snapshot, [:])
        XCTAssertEqual(cursor.trackedCount, 0)
    }

    func testShouldPushReturnsTrueForUnseenGuid() {
        let cursor = CalendarCursor(defaults: defaults)
        XCTAssertTrue(cursor.shouldPush(guid: "new", modifiedAt: Date()))
    }

    func testNilModifiedAtPushesOnFirstSightingOnly() {
        // A nil lastModifiedDate pushes once (fresh sighting) and is
        // recorded at the sentinel; re-pushing it every cycle would
        // burn a batch slot forever and starve rows sorted after it.
        // A later real timestamp compares newer than the sentinel and
        // re-pushes.
        let cursor = CalendarCursor(defaults: defaults)
        XCTAssertTrue(cursor.shouldPush(guid: "g", modifiedAt: nil))
        cursor.advance([(guid: "g", modifiedAt: nil as Date?)])
        XCTAssertFalse(cursor.shouldPush(guid: "g", modifiedAt: nil))
        XCTAssertTrue(cursor.shouldPush(guid: "g", modifiedAt: Date()))
    }

    func testAdvanceAndShouldPushRespectsTimestamp() {
        let cursor = CalendarCursor(defaults: defaults)
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        cursor.advance([(guid: "g", modifiedAt: t)])
        XCTAssertFalse(cursor.shouldPush(guid: "g", modifiedAt: t))
        XCTAssertFalse(cursor.shouldPush(guid: "g", modifiedAt: t.addingTimeInterval(-1)))
        XCTAssertTrue(cursor.shouldPush(guid: "g", modifiedAt: t.addingTimeInterval(1)))
    }

    func testAdvancePreservesUnrelatedEntries() {
        let cursor = CalendarCursor(defaults: defaults)
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        cursor.advance([
            (guid: "a", modifiedAt: t),
            (guid: "b", modifiedAt: t.addingTimeInterval(60))
        ])
        cursor.advance([(guid: "a", modifiedAt: t.addingTimeInterval(120))])

        XCTAssertEqual(cursor.trackedCount, 2)
        let snap = cursor.snapshot
        XCTAssertEqual(snap["a"], t.addingTimeInterval(120))
        XCTAssertEqual(snap["b"], t.addingTimeInterval(60))
    }

    func testResetClearsSnapshot() {
        let cursor = CalendarCursor(defaults: defaults)
        cursor.advance([(guid: "g", modifiedAt: Date())])
        XCTAssertEqual(cursor.trackedCount, 1)
        cursor.reset()
        XCTAssertEqual(cursor.trackedCount, 0)
    }
}
