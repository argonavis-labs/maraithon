import XCTest
@testable import Maraithon

final class ConnectCopyTests: XCTestCase {
    func testPairingCopyNamesRealLocalSources() {
        XCTAssertEqual(ConnectCopy.title, "Connect to Maraithon")
        XCTAssertTrue(ConnectCopy.body.contains("Messages"))
        XCTAssertTrue(ConnectCopy.body.contains("Notes"))
        XCTAssertTrue(ConnectCopy.body.contains("Voice Memos"))
        XCTAssertTrue(ConnectCopy.body.contains("Calendar"))
        XCTAssertTrue(ConnectCopy.body.contains("Reminders"))
        XCTAssertTrue(ConnectCopy.body.contains("files"))
        XCTAssertTrue(ConnectCopy.body.contains("browser history"))
    }

    func testPairingCopyAvoidsVagueOrSingleSourceSetupLanguage() {
        XCTAssertEqual(ConnectCopy.connectButton, "Connect")
        XCTAssertFalse(ConnectCopy.body.localizedCaseInsensitiveContains("other local context"))
        XCTAssertFalse(ConnectCopy.body.localizedCaseInsensitiveContains("assistant"))
        XCTAssertFalse(ConnectCopy.body.localizedCaseInsensitiveContains("iMessage and"))
    }
}
