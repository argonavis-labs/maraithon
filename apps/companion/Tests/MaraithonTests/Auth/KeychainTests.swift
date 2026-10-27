import XCTest
@testable import Maraithon

final class KeychainTests: XCTestCase {
    func testInMemoryKeychainRoundTripsValues() throws {
        let kc = InMemoryKeychain()
        XCTAssertNil(try kc.get())

        try kc.set("hello")
        XCTAssertEqual(try kc.get(), "hello")

        try kc.set("replaced")
        XCTAssertEqual(try kc.get(), "replaced")

        try kc.delete()
        XCTAssertNil(try kc.get())
    }

    func testInMemoryKeychainDeleteOnEmptyIsNoOp() throws {
        let kc = InMemoryKeychain()
        XCTAssertNoThrow(try kc.delete())
        XCTAssertNil(try kc.get())
    }

    func testInMemoryKeychainSeededValue() throws {
        let kc = InMemoryKeychain(initial: "seeded")
        XCTAssertEqual(try kc.get(), "seeded")
    }
}
