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
            "Some items could not finish. Maraithon will keep the last successful context until the next check."
        )

        let transport = "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\""
        XCTAssertEqual(
            SourceIssueCopy.status(transport),
            "Connection issue. Check again when you are online."
        )

        let serverError = "serverError(status: 503, body: Optional(\"database token=secret\"))"
        let serverCopy = SourceIssueCopy.status(serverError)
        XCTAssertEqual(
            serverCopy,
            "Maraithon could not reach its cloud service. Check again shortly."
        )
        XCTAssertFalse(serverCopy.localizedCaseInsensitiveContains("temporarily unavailable"))
        XCTAssertFalse(serverCopy.localizedCaseInsensitiveContains("database"))
        XCTAssertFalse(serverCopy.localizedCaseInsensitiveContains("token"))
    }

    func testUnknownMachineCodesUseGenericRecoveryCopy() {
        XCTAssertEqual(
            SourceIssueCopy.status("something_weird"),
            "Maraithon could not finish this check. Check again when ready."
        )
    }

    func testCredentialLikeReasonsUseGenericRecoveryCopy() {
        let copy = SourceIssueCopy.status("Authorization: Bearer abc123 token=secret")

        XCTAssertEqual(copy, "Maraithon could not finish this check. Check again when ready.")
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

    func testUnsupportedSyncEventsUseUpdateCopyWithoutServerLanguage() {
        let copy = SourceIssueCopy.status("unknown_event")

        XCTAssertEqual(
            copy,
            "This companion app needs an update before it can check this source. Update Maraithon, then check again."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("server"))
    }

    func testInvalidSyncAddressCopyAvoidsServerURLLanguage() {
        let copy = SourceIssueCopy.status("invalid_url")

        XCTAssertEqual(
            copy,
            "Maraithon is missing a valid connection address. Check the app settings, then check again."
        )
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("server"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("URL"))
    }

    func testServerRejectionSummariesUseRecoveryCopy() {
        XCTAssertEqual(
            SourceIssueCopy.status("2 messages were rejected by the server."),
            "Some items could not finish. Maraithon will keep the last successful context until the next check."
        )
    }

    func testStoredSyncFailureSummariesUseCheckLanguage() {
        let status = SourceIssueCopy.status("2 messages did not sync.")
        let detail = SourceIssueCopy.detail("1 item did not sync.", sourceName: "iMessage")
        let visibleCopy = [status, detail].joined(separator: " ")

        XCTAssertEqual(
            status,
            "Some items need another check. Maraithon will keep the last successful context until the next check."
        )
        XCTAssertEqual(
            detail,
            "iMessage could not finish its last check. Some items need another check. Maraithon will keep the last successful context until the next check. Check again when ready."
        )
        XCTAssertFalse(visibleCopy.localizedCaseInsensitiveContains("sync"))
    }

    func testDetailUsesVisibleRecoveryActionInsteadOfHiddenLogs() {
        let detail = SourceIssueCopy.detail(
            "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"",
            sourceName: "Notes"
        )

        XCTAssertEqual(
            detail,
            "Notes could not finish its last check. Connection issue. Check again when you are online."
        )
        XCTAssertFalse(detail.contains("Logs"))
        XCTAssertFalse(detail.lowercased().contains("diagnostic"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("source detail"))
    }

    func testSourceIssueCopyUsesCheckLanguageInsteadOfSyncJargon() {
        let copies = [
            SourceIssueCopy.status("something_weird"),
            SourceIssueCopy.status("clientError(status: 400, body: Optional(\"{}\"))"),
            SourceIssueCopy.status("serverError(status: 503)"),
            SourceIssueCopy.detail("timed_out", sourceName: "Files")
        ]

        XCTAssertFalse(copies.joined(separator: " ").localizedCaseInsensitiveContains("sync again"))
        XCTAssertFalse(copies.joined(separator: " ").localizedCaseInsensitiveContains("last successful data"))
        XCTAssertTrue(copies.joined(separator: " ").localizedCaseInsensitiveContains("check"))
    }
}
