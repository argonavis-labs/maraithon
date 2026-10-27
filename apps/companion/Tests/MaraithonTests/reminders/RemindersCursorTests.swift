import XCTest
@testable import Maraithon

final class RemindersCursorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "com.maraithon.companion.reminders-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testFirstRunSnapshotIsEmpty() {
        let cursor = RemindersCursor(defaults: defaults)
        XCTAssertTrue(cursor.snapshot.isEmpty)
        XCTAssertEqual(cursor.trackedCount, 0)
    }

    func testShouldPushTrueForUnseenGuid() {
        let cursor = RemindersCursor(defaults: defaults)
        XCTAssertTrue(cursor.shouldPush(guid: "abc", modifiedAt: Date()))
    }

    func testShouldPushFalseForStaleModification() {
        let cursor = RemindersCursor(defaults: defaults)
        let t1 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        cursor.advance([(guid: "g", modifiedAt: t1)])

        // Same modifiedAt: not strictly newer → no push.
        XCTAssertFalse(cursor.shouldPush(guid: "g", modifiedAt: t1))
        // Older modifiedAt: definitely not.
        XCTAssertFalse(
            cursor.shouldPush(
                guid: "g",
                modifiedAt: t1.addingTimeInterval(-60)
            )
        )
    }

    func testShouldPushTrueForAdvancedModification() {
        let cursor = RemindersCursor(defaults: defaults)
        let t1 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        cursor.advance([(guid: "g", modifiedAt: t1)])

        XCTAssertTrue(
            cursor.shouldPush(guid: "g", modifiedAt: t1.addingTimeInterval(1))
        )
    }

    func testNilModifiedAtPushesOnFirstSightingOnly() {
        // EventKit can hand us a reminder without a lastModifiedDate
        // (rare, but possible for very old rows). It pushes once as a
        // fresh sighting and is recorded at the sentinel — re-pushing
        // it every cycle would burn a batch slot forever and starve
        // rows sorted after it. A later real timestamp compares newer
        // than the sentinel and re-pushes.
        let cursor = RemindersCursor(defaults: defaults)
        XCTAssertTrue(cursor.shouldPush(guid: "g", modifiedAt: nil))
        cursor.advance([(guid: "g", modifiedAt: nil as Date?)])
        XCTAssertFalse(cursor.shouldPush(guid: "g", modifiedAt: nil))
        XCTAssertTrue(cursor.shouldPush(guid: "g", modifiedAt: Date()))
    }

    func testAdvanceMergesEntries() {
        let cursor = RemindersCursor(defaults: defaults)
        let t1 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        cursor.advance([
            (guid: "a", modifiedAt: t1),
            (guid: "b", modifiedAt: t1.addingTimeInterval(60))
        ])

        cursor.advance([(guid: "c", modifiedAt: t1.addingTimeInterval(120))])

        XCTAssertEqual(cursor.trackedCount, 3)
        let snapshot = cursor.snapshot
        XCTAssertEqual(snapshot["a"], t1)
        XCTAssertEqual(snapshot["b"], t1.addingTimeInterval(60))
        XCTAssertEqual(snapshot["c"], t1.addingTimeInterval(120))
    }

    func testResetWipesSnapshot() {
        let cursor = RemindersCursor(defaults: defaults)
        cursor.advance([(guid: "g", modifiedAt: Date())])
        XCTAssertEqual(cursor.trackedCount, 1)

        cursor.reset()
        XCTAssertEqual(cursor.trackedCount, 0)
        XCTAssertTrue(cursor.snapshot.isEmpty)
    }

    func testEmptyAdvanceIsNoOp() {
        let cursor = RemindersCursor(defaults: defaults)
        cursor.advance([])
        XCTAssertEqual(cursor.trackedCount, 0)
    }
}
