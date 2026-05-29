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
            "Some items could not be synced. Try again."
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
            "This source needs attention. Try again."
        )
    }

    func testCredentialLikeReasonsUseGenericRecoveryCopy() {
        let copy = SourceIssueCopy.status("Authorization: Bearer abc123 token=secret")

        XCTAssertEqual(copy, "This source needs attention. Try again.")
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
            "Some items did not sync. Try again."
        )
    }

    func testDetailUsesVisibleRecoveryActionInsteadOfHiddenLogs() {
        let detail = SourceIssueCopy.detail(
            "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"",
            sourceName: "Notes"
        )

        XCTAssertEqual(
            detail,
            "Notes could not finish its last sync. Connection issue. Sync again when you are online. Select Sync now to try again."
        )
        XCTAssertFalse(detail.contains("Logs"))
        XCTAssertFalse(detail.lowercased().contains("diagnostic"))
    }
}
