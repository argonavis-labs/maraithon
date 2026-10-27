import XCTest
@testable import Maraithon

final class LogDisplayCopyTests: XCTestCase {
    func testLogMetadataLabelsAreReadable() {
        XCTAssertEqual(LogDisplayCopy.label(for: LogLevel.debug), "Debug")
        XCTAssertEqual(LogDisplayCopy.label(for: LogLevel.info), "Info")
        XCTAssertEqual(LogDisplayCopy.label(for: LogLevel.warning), "Warning")
        XCTAssertEqual(LogDisplayCopy.label(for: LogLevel.error), "Error")

        XCTAssertEqual(LogDisplayCopy.label(for: LogSource.imessage), "iMessage")
        XCTAssertEqual(LogDisplayCopy.label(for: LogSource.voiceMemos), "Voice Memos")
        XCTAssertEqual(LogDisplayCopy.label(for: LogSource.realtime), "Live updates")
        XCTAssertEqual(LogDisplayCopy.label(for: LogSource.ui), "App UI")
    }

    func testLogLabelsDoNotExposeRawEnumFormatting() {
        let visibleCopy =
            LogLevel.allCases.map(LogDisplayCopy.label(for:)).joined(separator: " ") + " " +
            LogSource.allCases.map(LogDisplayCopy.label(for:)).joined(separator: " ") + " " +
            [
                LogDisplayCopy.detailsSectionTitle,
                LogDisplayCopy.noSelectionTitle,
                LogDisplayCopy.noSelectionDescription,
                LogDisplayCopy.copiedRowsHeader
            ].joined(separator: " ")

        XCTAssertFalse(visibleCopy.contains("voice_memos"))
        XCTAssertFalse(visibleCopy.contains("imessage"))
        XCTAssertFalse(visibleCopy.contains("realtime"))
        XCTAssertFalse(visibleCopy.contains("payload"))
        XCTAssertFalse(visibleCopy.contains("WARNING"))
    }
}
