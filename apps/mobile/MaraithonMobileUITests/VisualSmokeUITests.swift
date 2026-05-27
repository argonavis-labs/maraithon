import XCTest

final class VisualSmokeUITests: XCTestCase {
    private struct VisualConfig: Decodable {
        let magicCode: String
        let snapshotDirectory: String
    }

    private static let fallbackConfigURL = URL(fileURLWithPath: "/tmp/maraithon-visual-smoke.json")

    @MainActor
    func testCapturePrimaryTabs() throws {
        let environment = ProcessInfo.processInfo.environment
        let fileConfig = loadFallbackConfig()

        guard let snapshotDirectory = environment["MARAITHON_VISUAL_SNAPSHOT_DIR"] ?? fileConfig?.snapshotDirectory,
              !snapshotDirectory.isEmpty else {
            throw XCTSkip("Set MARAITHON_VISUAL_SNAPSHOT_DIR to capture visual smoke screenshots.")
        }

        guard let magicCode = environment["MARAITHON_MAGIC_CODE"] ?? fileConfig?.magicCode,
              !magicCode.isEmpty,
              !magicCode.contains("$(") else {
            throw XCTSkip("Set MARAITHON_MAGIC_CODE to capture signed-in visual smoke screenshots.")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launchEnvironment["MARAITHON_UI_TEST_MAGIC_CODE"] = magicCode
        app.launchEnvironment["MARAITHON_UI_TEST_RESET_STATE"] = "1"
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 60), app.debugDescription)

        try capture("today", in: snapshotDirectory)
        try tapTab("Todos", app: app)
        try capture("todos", in: snapshotDirectory)
        try tapTab("People", app: app)
        try capture("people", in: snapshotDirectory)
        try tapTab("Chat", app: app)
        try capture("chat", in: snapshotDirectory)
        app.buttons["New Chat"].firstMatch.tap()
        sleep(1)
        try capture("chat-detail", in: snapshotDirectory)
    }

    @MainActor
    private func tapTab(_ title: String, app: XCUIApplication) throws {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        tab.tap()
        sleep(1)
    }

    @MainActor
    private func capture(_ name: String, in directory: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func loadFallbackConfig() -> VisualConfig? {
        guard FileManager.default.fileExists(atPath: Self.fallbackConfigURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: Self.fallbackConfigURL)
            return try JSONDecoder().decode(VisualConfig.self, from: data)
        } catch {
            XCTFail("Unable to read visual smoke config: \(error)")
            return nil
        }
    }
}
