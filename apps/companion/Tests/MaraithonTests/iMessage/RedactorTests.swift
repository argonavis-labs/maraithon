import XCTest
@testable import Maraithon

final class RedactorTests: XCTestCase {
    func testRedactsCanonicalE164Phone() {
        XCTAssertEqual(Redactor.redact("+14165550199"), "+1416***0199")
    }

    func testRedactsEmail() {
        XCTAssertEqual(Redactor.redact("kent@example.com"), "k***@example.com")
    }

    func testRedactsEmailWithLongLocalPart() {
        XCTAssertEqual(Redactor.redact("joe.user@example.com"), "j***@example.com")
    }

    func testRedactsAllForGroupChat() {
        let masked = Redactor.redactAll(["+14165550199", "kent@example.com"])
        XCTAssertEqual(masked, "+1416***0199,k***@example.com")
    }

    func testPassesThroughUnrecognisedString() {
        XCTAssertEqual(Redactor.redact("system"), "system")
    }
}
