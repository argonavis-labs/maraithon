import XCTest
@testable import Maraithon

@MainActor
final class EventLogTests: XCTestCase {
    func testAutomaticPersistenceIsMemoryOnlyUnderXCTest() {
        let log = EventLog(capacity: 10)

        log.info("event_log.test_marker", source: .system)

        XCTAssertNil(log.logFileURL)
        XCTAssertEqual(log.entries.last?.message, "event_log.test_marker")
    }

    func testExplicitFilePersistenceWritesRedactedLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-log-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("companion.log")
        let log = EventLog(capacity: 10, persistence: .file(fileURL))

        log.error(
            "event_log.persist token=file-secret",
            source: .system,
            payload: ["authorization": "Authorization: Bearer bearer-secret"]
        )

        let rendered = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(rendered.contains("event_log.persist"))
        XCTAssertFalse(rendered.contains("file-secret"))
        XCTAssertFalse(rendered.contains("bearer-secret"))
        XCTAssertTrue(rendered.contains("token=[redacted]"))
        XCTAssertTrue(rendered.contains("Bearer [redacted]"))
    }

    func testAppendRedactsSensitiveTokensBeforeStoringEntries() {
        let log = EventLog(capacity: 10)
        let raw = """
        Error Domain=NSPOSIXErrorDomain Code=57 \
        NSErrorFailingURLStringKey=https://maraithon.com/companion/socket/websocket?token=socket-secret&vsn=2.0.0 \
        Authorization: Bearer bearer-secret maraithon://device-token/device-secret
        """

        log.error(
            "realtime.receive_error \(raw)",
            source: .realtime,
            payload: [
                "error": raw,
                "safe": "count=1"
            ]
        )

        let entry = log.entries.last!
        XCTAssertFalse(entry.message.contains("socket-secret"))
        XCTAssertFalse(entry.message.contains("bearer-secret"))
        XCTAssertFalse(entry.message.contains("device-secret"))
        XCTAssertFalse(entry.payload["error"]!.contains("socket-secret"))
        XCTAssertFalse(entry.payload["error"]!.contains("bearer-secret"))
        XCTAssertFalse(entry.payload["error"]!.contains("device-secret"))
        XCTAssertTrue(entry.payload["error"]!.contains("token=[redacted]"))
        XCTAssertTrue(entry.payload["error"]!.contains("Code=57"))
        XCTAssertEqual(entry.payload["safe"], "count=1")
    }

    func testRedactsJsonAndEnvironmentStyleSecrets() {
        let raw = #"{"token":"json-secret","api_key":"api-secret"} MARAITHON_API_TOKEN=env-secret"#
        let redacted = EventLog.redactSensitiveLogText(raw)

        XCTAssertFalse(redacted.contains("json-secret"))
        XCTAssertFalse(redacted.contains("api-secret"))
        XCTAssertFalse(redacted.contains("env-secret"))
        XCTAssertTrue(redacted.contains(#""token":"[redacted]""#))
        XCTAssertTrue(redacted.contains("MARAITHON_API_TOKEN=[redacted]"))
    }
}
