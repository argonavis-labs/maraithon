import XCTest
@testable import Maraithon

final class DeviceTokenTests: XCTestCase {
    func testParsesValidDeepLink() throws {
        let url = try XCTUnwrap(URL(string: "maraithon://device-token/abc123"))
        let token = try XCTUnwrap(DeviceToken(url: url))
        XCTAssertEqual(token.plain, "abc123")
    }

    func testRejectsWrongScheme() {
        let url = URL(string: "https://device-token/abc123")!
        XCTAssertNil(DeviceToken(url: url))
    }

    func testRejectsWrongHost() {
        let url = URL(string: "maraithon://other/abc123")!
        XCTAssertNil(DeviceToken(url: url))
    }

    func testRejectsEmptyToken() {
        let url = URL(string: "maraithon://device-token/")!
        XCTAssertNil(DeviceToken(url: url))
    }

    func testParsesWithTrailingSlash() throws {
        let url = try XCTUnwrap(URL(string: "maraithon://device-token/tok/"))
        XCTAssertEqual(DeviceToken(url: url)?.plain, "tok")
    }
}
