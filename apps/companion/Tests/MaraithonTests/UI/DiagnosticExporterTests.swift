import XCTest
@testable import Maraithon

/// Tests the diagnostic-bundle exporter. The exporter writes a zip into
/// the user's Downloads folder; tests drive it against a temp directory
/// instead and assert on the produced manifest + redacted payload shape.
@MainActor
final class DiagnosticExporterTests: XCTestCase {
    private var tempDir: URL!
    private var downloadsDir: URL!
    private var logsDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-exporter-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        downloadsDir = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Put a stub companion.log in place so the copy step runs.
        let logFile = logsDir.appendingPathComponent("companion.log")
        try? "test log line\n".data(using: .utf8)?.write(to: logFile)
        let rotated = logsDir.appendingPathComponent("companion.log.1")
        try? "rotated\n".data(using: .utf8)?.write(to: rotated)

        suiteName = "diag-exporter-defaults-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set("preserved", forKey: "com.maraithon.companion.device_id")
        defaults.set("unrelated", forKey: "some.other.app.key")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFilenameMatchesPattern() throws {
        let log = EventLog()
        let device = UUID()
        let result = try DiagnosticExporter.export(
            log: log,
            deviceId: device,
            appVersion: "1.0",
            recentEntries: [],
            downloadsDirectory: downloadsDir,
            defaults: defaults,
            sourceLogsDirectory: logsDir,
            revealInFinder: false
        )
        let name = result.bundleURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("Maraithon-Diagnostics-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
        // Contains the short device hash (8 hex chars).
        let hash = DiagnosticExporter.shortDeviceHash(device)
        XCTAssertEqual(hash.count, 8)
        XCTAssertTrue(name.contains(hash))
    }

    func testCursorSnapshotIsWhitelisted() {
        let snapshot = DiagnosticExporter.cursorSnapshotJSON(defaults: defaults)
        let dict = try? JSONSerialization.jsonObject(with: snapshot) as? [String: String]
        XCTAssertEqual(dict?["com.maraithon.companion.device_id"], "preserved")
        XCTAssertNil(dict?["some.other.app.key"], "Non-prefixed defaults must not leak into the bundle")
    }

    func testRedactedEventsScrubsHandlesInPayload() throws {
        let entry = LogEntry(
            level: .info,
            source: .imessage,
            message: "msg.received",
            payload: [
                "from": "+14165550199",
                "to": "kent@example.com",
                "count": "1"
            ]
        )
        let data = try DiagnosticExporter.redactedEventsJSON([entry])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let first = try XCTUnwrap(json.first)
        let payload = try XCTUnwrap(first["payload"] as? [String: String])
        XCTAssertFalse(payload["from"]!.contains("4165550199"), "Phone should be redacted: \(payload["from"]!)")
        XCTAssertFalse(payload["to"]!.contains("kent@example"), "Email local-part should be redacted: \(payload["to"]!)")
        // Non-handle keys pass through.
        XCTAssertEqual(payload["count"], "1")
    }

    func testManifestCarriesDeviceHashAndVersion() throws {
        let device = UUID()
        let data = try DiagnosticExporter.manifestJSON(
            deviceId: device,
            appVersion: "2.3.4",
            entryCount: 12
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["device_hash"] as? String, DiagnosticExporter.shortDeviceHash(device))
        XCTAssertEqual(json["app_version"] as? String, "2.3.4")
        XCTAssertEqual(json["entry_count"] as? Int, 12)
        XCTAssertEqual(json["schema_version"] as? Int, 1)
    }

    func testShortDeviceHashIsDeterministic() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let a = DiagnosticExporter.shortDeviceHash(uuid)
        let b = DiagnosticExporter.shortDeviceHash(uuid)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 8)
    }

    func testZipBundleExistsAndIsNonEmpty() throws {
        let log = EventLog()
        let result = try DiagnosticExporter.export(
            log: log,
            deviceId: UUID(),
            appVersion: "0.1.0",
            recentEntries: [
                LogEntry(level: .info, source: .ui, message: "boot", payload: [:])
            ],
            downloadsDirectory: downloadsDir,
            defaults: defaults,
            sourceLogsDirectory: logsDir,
            revealInFinder: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
        XCTAssertGreaterThan(result.byteCount, 0)
    }
}
