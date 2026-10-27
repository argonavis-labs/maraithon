import CoreSpotlight
import XCTest
@testable import Maraithon

/// Verifies the parsing half of the deep-link round-trip. The actual
/// `application(_:continue:restorationHandler:)` plumbing lives in
/// `MaraithonApp.swift` and calls `parseSpotlightActivityIdentifier`
/// → `environment.handleIncomingURL`. We test the parser directly
/// because the SwiftUI scene wiring is not unit-testable.
final class SpotlightActivityRoutingTests: XCTestCase {

    func testParsesValidIdentifierIntoSourceGuidAndURL() throws {
        let route = try XCTUnwrap(parseSpotlightActivityIdentifier("notes:NOTE-42"))
        XCTAssertEqual(route.source, "notes")
        XCTAssertEqual(route.guid, "NOTE-42")
        XCTAssertEqual(
            route.url.absoluteString,
            "maraithon://open/notes/NOTE-42"
        )
    }

    func testParsesGuidContainingHyphensAndDigits() throws {
        let route = try XCTUnwrap(parseSpotlightActivityIdentifier("calendar:abcd-1234-EFGH"))
        XCTAssertEqual(route.source, "calendar")
        XCTAssertEqual(route.guid, "abcd-1234-EFGH")
        XCTAssertEqual(
            route.url.absoluteString,
            "maraithon://open/calendar/abcd-1234-EFGH"
        )
    }

    func testRejectsIdentifierWithoutColon() {
        XCTAssertNil(parseSpotlightActivityIdentifier("not-a-spotlight-id"))
    }

    func testRejectsEmptySourceOrGuid() {
        XCTAssertNil(parseSpotlightActivityIdentifier(":NOTE-1"))
        XCTAssertNil(parseSpotlightActivityIdentifier("notes:"))
        XCTAssertNil(parseSpotlightActivityIdentifier(""))
        XCTAssertNil(parseSpotlightActivityIdentifier(":"))
    }

    func testEncodesGuidContainingPathDelimiters() throws {
        // Defensive: if a future source ever emits a guid with `/` or
        // `#`, we must percent-encode it so the URL parser doesn't
        // truncate. None of the v6 sources do this today, but the
        // parser shouldn't be the thing that breaks if they start.
        let route = try XCTUnwrap(parseSpotlightActivityIdentifier("files:a/b#c"))
        XCTAssertEqual(route.source, "files")
        XCTAssertEqual(route.guid, "a/b#c")
        XCTAssertTrue(route.url.absoluteString.hasPrefix("maraithon://open/files/"))
        // The encoded URL should be a parseable URL with a non-empty path.
        XCTAssertFalse(route.url.path.isEmpty)
    }
}
