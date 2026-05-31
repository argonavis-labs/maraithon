import XCTest
@testable import Maraithon

final class CompanionErrorCopyTests: XCTestCase {
    func testClientErrorsHideResponseBodies() {
        let copy = CompanionErrorCopy.message(
            for: MaraithonClientError.clientError(
                status: 400,
                body: "{\"error\":\"invalid_batch\",\"secret\":\"abc\"}"
            )
        )

        XCTAssertEqual(copy, "Request did not complete. Saved data was left unchanged.")
        XCTAssertFalse(copy.contains("invalid_batch"))
        XCTAssertFalse(copy.contains("secret"))
    }

    func testClientErrorsUseSafeServerMessages() {
        let copy = CompanionErrorCopy.message(
            for: MaraithonClientError.clientError(
                status: 404,
                body: "{\"error\":\"device_not_found\",\"message\":\"That Mac is no longer paired. Refresh the device list; pair it again if it should keep checking this Mac.\",\"secret\":\"abc\"}"
            )
        )

        XCTAssertEqual(copy, "That Mac is no longer paired. Refresh the device list; pair it again if it should keep checking this Mac.")
        XCTAssertFalse(copy.contains("device_not_found"))
        XCTAssertFalse(copy.contains("secret"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("sync"))
    }

    func testClientErrorsRejectTechnicalServerMessages() {
        let copy = CompanionErrorCopy.message(
            for: MaraithonClientError.clientError(
                status: 400,
                body: "{\"error\":\"invalid_device_key\",\"message\":\"Postgrex.Exception token=secret\"}"
            )
        )

        XCTAssertEqual(copy, "Request did not complete. Saved data was left unchanged.")
        XCTAssertFalse(copy.contains("Postgrex"))
        XCTAssertFalse(copy.contains("token=secret"))
    }

    func testClientErrorsRejectCredentialServerMessages() {
        let copy = CompanionErrorCopy.message(
            for: MaraithonClientError.clientError(
                status: 400,
                body: "{\"message\":\"Authorization: Bearer abc123\"}"
            )
        )

        XCTAssertEqual(copy, "Request did not complete. Saved data was left unchanged.")
        XCTAssertFalse(copy.lowercased().contains("authorization"))
        XCTAssertFalse(copy.lowercased().contains("bearer"))
        XCTAssertFalse(copy.contains("abc123"))
    }

    func testTransportErrorsUseRecoveryCopy() {
        let copy = CompanionErrorCopy.message(
            for: MaraithonClientError.transport(message: "NSURLErrorDomain Code=-1009")
        )

        XCTAssertEqual(copy, "Connection issue. Retry when you are online.")
        XCTAssertFalse(copy.contains("NSURLErrorDomain"))
    }

    func testLargeRequestsUsePlainRecoveryCopy() {
        let copy = CompanionErrorCopy.message(
            for: MaraithonClientError.clientError(status: 413, body: nil)
        )

        XCTAssertEqual(copy, "That request was too large. Try fewer items.")
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("sync"))
    }

    func testStringReasonsHideTechnicalValues() {
        XCTAssertEqual(
            CompanionErrorCopy.message(for: "clientError(status: 401, body: nil)"),
            "Reconnect Maraithon to continue."
        )

        XCTAssertEqual(
            CompanionErrorCopy.message(for: "some_internal_code"),
            "Request did not complete. Saved data was left unchanged."
        )
    }

    func testStringReasonsHideCredentialValues() {
        let copy = CompanionErrorCopy.message(for: "Authorization: Bearer abc123 token=secret")

        XCTAssertEqual(copy, "Request did not complete. Saved data was left unchanged.")
        XCTAssertFalse(copy.lowercased().contains("authorization"))
        XCTAssertFalse(copy.lowercased().contains("bearer"))
        XCTAssertFalse(copy.lowercased().contains("token"))
        XCTAssertFalse(copy.contains("abc123"))
    }
}
