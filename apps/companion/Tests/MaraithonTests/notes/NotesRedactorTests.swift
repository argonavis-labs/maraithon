import XCTest
@testable import Maraithon

/// Smoke tests for `NotesRedactor`. The function isn't reached from the
/// wire path — only logging — but a regression here would leak note
/// contents into `~/Library/Logs/Maraithon/companion.log`, so we lock
/// the shape down explicitly.
final class NotesRedactorTests: XCTestCase {
    func testNilIsRenderedSafely() {
        XCTAssertEqual(NotesRedactor.redact(nil), "<nil>")
    }

    func testShortTextSurfacesLengthOnly() {
        // <= 12 chars: include the raw text alongside the length tag.
        // Length tag is still required so log readers can spot
        // empty-vs-noisy rows.
        XCTAssertEqual(NotesRedactor.redact("hi"), "[len=2] hi")
        XCTAssertEqual(NotesRedactor.redact("12char12char"), "[len=12] 12char12char")
    }

    func testLongTextIsTruncated() {
        let title = "Grocery list and reminders for tomorrow morning"
        let redacted = NotesRedactor.redact(title)
        XCTAssertTrue(redacted.hasPrefix("[len=\(title.count)] "))
        // First 12 chars of the original + ellipsis.
        XCTAssertTrue(redacted.contains("Grocery list…"),
                      "redacted prefix should be the first 12 chars + ellipsis, got: \(redacted)")
        XCTAssertFalse(redacted.contains("reminders"),
                       "long suffix must not appear in the redacted output")
    }

    func testEmptyStringRendersWithZeroLength() {
        XCTAssertEqual(NotesRedactor.redact(""), "[len=0] ")
    }
}

/// Tiny set of tests for the cursor. Same UserDefaults-suite pattern
/// `IMessageCursor` uses, so we cover the monotonic-progress and
/// reset semantics without coupling to the source.
final class NotesCursorTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "com.maraithon.companion.notes-cursor-tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(suite)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        suite?.removePersistentDomain(forName: suiteName)
    }

    func testStartsAtZero() {
        XCTAssertEqual(NotesCursor(defaults: suite).lastSyncedRowID, 0)
    }

    func testAdvanceMovesForward() {
        let cursor = NotesCursor(defaults: suite)
        cursor.advance(to: 42)
        XCTAssertEqual(cursor.lastSyncedRowID, 42)
    }

    func testAdvanceRefusesToMoveBackward() {
        let cursor = NotesCursor(defaults: suite)
        cursor.advance(to: 100)
        cursor.advance(to: 5)
        XCTAssertEqual(cursor.lastSyncedRowID, 100)
    }

    func testResetClearsValue() {
        let cursor = NotesCursor(defaults: suite)
        cursor.advance(to: 7)
        cursor.reset()
        XCTAssertEqual(cursor.lastSyncedRowID, 0)
    }
}
