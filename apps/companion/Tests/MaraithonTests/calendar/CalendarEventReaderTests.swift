import XCTest
@testable import Maraithon

final class CalendarEventReaderTests: XCTestCase {

    func testDerivedGuidIncludesStartForRecurrenceDisambiguation() {
        let t1 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let t2 = Date(timeIntervalSinceReferenceDate: 1_000_060)
        let g1 = CalendarEventReader.derivedGuid(masterIdentifier: "MASTER", startAt: t1)
        let g2 = CalendarEventReader.derivedGuid(masterIdentifier: "MASTER", startAt: t2)
        XCTAssertNotEqual(g1, g2)
        XCTAssertTrue(g1.hasPrefix("MASTER@"))
    }

    func testDerivedGuidWithNilStartFallsBackToMasterIdentifier() {
        let guid = CalendarEventReader.derivedGuid(masterIdentifier: "MASTER", startAt: nil)
        XCTAssertEqual(guid, "MASTER")
    }

    func testEmailFromMailtoStripsScheme() {
        XCTAssertEqual(
            CalendarEventReader.emailFromMailto("mailto:kent@example.com"),
            "kent@example.com"
        )
    }

    func testEmailFromMailtoLeavesBareAddressAlone() {
        XCTAssertEqual(
            CalendarEventReader.emailFromMailto("kent@example.com"),
            "kent@example.com"
        )
    }

    func testEmailFromMailtoRejectsNonAddressString() {
        XCTAssertNil(CalendarEventReader.emailFromMailto("not-an-email"))
        XCTAssertNil(CalendarEventReader.emailFromMailto("mailto:"))
    }
}
