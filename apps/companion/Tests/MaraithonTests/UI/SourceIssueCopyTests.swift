import XCTest
@testable import Maraithon

final class SourceIssueCopyTests: XCTestCase {
    func testPermissionCodesMapToPlainEnglish() {
        XCTAssertEqual(
            SourceIssueCopy.status("calendar_not_authorized"),
            "Calendar permission is off."
        )
        XCTAssertEqual(
            SourceIssueCopy.status("voice_memos_full_disk_access_required"),
            "Full Disk Access is required."
        )
        XCTAssertEqual(
            SourceIssueCopy.status("imessage_full_disk_access_required"),
            "Full Disk Access is required."
        )
        XCTAssertEqual(
            SourceIssueCopy.status("notes_full_disk_access_required"),
            "Full Disk Access is required."
        )
    }

    func testTransportAndServerErrorsDoNotLeakRawDumps() {
        let clientError = "clientError(status: 400, body: Optional(\"{\\\"error\\\":\\\"invalid_batch\\\",\\\"secret\\\":\\\"abc\\\"}\"))"
        XCTAssertEqual(
            SourceIssueCopy.status(clientError),
            "Some items were not accepted. Maraithon will keep the last successful data until the next sync."
        )

        let transport = "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\""
        XCTAssertEqual(
            SourceIssueCopy.status(transport),
            "Connection issue. Sync again when you are online."
        )
    }

    func testUnknownMachineCodesUseGenericRecoveryCopy() {
        XCTAssertEqual(
            SourceIssueCopy.status("something_weird"),
            "This source needs attention. Open the source detail before syncing again."
        )
    }

    func testCredentialLikeReasonsUseGenericRecoveryCopy() {
        let copy = SourceIssueCopy.status("Authorization: Bearer abc123 token=secret")

        XCTAssertEqual(copy, "This source needs attention. Open the source detail before syncing again.")
        XCTAssertFalse(copy.lowercased().contains("authorization"))
        XCTAssertFalse(copy.lowercased().contains("bearer"))
        XCTAssertFalse(copy.lowercased().contains("token"))
        XCTAssertFalse(copy.contains("abc123"))
    }

    func testDeviceMismatchUsesPairingRecoveryCopy() {
        XCTAssertEqual(
            SourceIssueCopy.status("device_mismatch"),
            "This Mac is paired as a different device. Sign out and pair it again."
        )
    }

    func testServerRejectionSummariesUseRecoveryCopy() {
        XCTAssertEqual(
            SourceIssueCopy.status("2 messages were rejected by the server."),
            "Some items did not sync. Maraithon will keep the last successful data until the next sync."
        )
    }

    func testDetailUsesVisibleRecoveryActionInsteadOfHiddenLogs() {
        let detail = SourceIssueCopy.detail(
            "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"",
            sourceName: "Notes"
        )

        XCTAssertEqual(
            detail,
            "Notes could not finish its last check. Connection issue. Sync again when you are online. Select Sync now when ready."
        )
        XCTAssertFalse(detail.contains("Logs"))
        XCTAssertFalse(detail.lowercased().contains("diagnostic"))
    }
}
