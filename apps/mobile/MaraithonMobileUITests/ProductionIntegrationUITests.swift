import XCTest

final class ProductionIntegrationUITests: XCTestCase {
    private struct VerificationConfig: Decodable {
        let magicCode: String
        let runID: String
        let contactEmailDomain: String
    }

    private static let fallbackConfigURL = URL(
        fileURLWithPath: "/tmp/maraithon-production-verification.json"
    )

    private var verificationConfig: VerificationConfig!

    private var runID: String {
        verificationConfig?.runID ?? "manual"
    }

    private var todoTitle: String {
        "iOS prod work item \(runID)"
    }

    private var contactName: String {
        "iOS Prod Person \(runID)"
    }

    private var updatedContactNotes: String {
        "Updated from simulator \(runID)"
    }

    private var chatProbeText: String {
        "Hey"
    }

    @MainActor
    func testProductionMagicSigninTodoAndPeoplePersistence() throws {
        continueAfterFailure = false
        verificationConfig = loadVerificationConfig()
        guard isUsableCode(verificationConfig.magicCode) else { return }
        let app = launchApp()

        XCTAssertTrue(workTab(app: app).waitForExistence(timeout: 60), app.debugDescription)

        createAndCompleteTodo(app: app)
        createAndUpdateContact(app: app)
        chatWithAssistant(app: app)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let magicCode = verificationConfig.magicCode
        XCTAssertFalse(magicCode.isEmpty, "MARAITHON_MAGIC_CODE must contain a fresh production sign-in code.")

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launchEnvironment["MARAITHON_UI_TEST_MAGIC_CODE"] = magicCode
        app.launchEnvironment["MARAITHON_UI_TEST_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    private func loadVerificationConfig() -> VerificationConfig {
        let environment = ProcessInfo.processInfo.environment
        let fileConfig = loadFallbackConfig()
        let environmentCode = environment["MARAITHON_MAGIC_CODE"] ?? fileConfig?.magicCode ?? ""
        let contactEmailDomain = environment["MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN"] ?? fileConfig?.contactEmailDomain ?? ""
        XCTAssertTrue(
            isUsableCode(environmentCode),
            "MARAITHON_MAGIC_CODE must be passed through the test scheme as a fresh production sign-in code."
        )
        XCTAssertFalse(
            contactEmailDomain.isEmpty,
            "MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN must be passed through the test scheme."
        )

        return VerificationConfig(
            magicCode: environmentCode,
            runID: environment["MARAITHON_VERIFY_RUN_ID"] ?? fileConfig?.runID ?? "manual",
            contactEmailDomain: contactEmailDomain
        )
    }

    private func loadFallbackConfig() -> VerificationConfig? {
        guard FileManager.default.fileExists(atPath: Self.fallbackConfigURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: Self.fallbackConfigURL)
            return try JSONDecoder().decode(VerificationConfig.self, from: data)
        } catch {
            XCTFail("Unable to read production verification config: \(error)")
            return nil
        }
    }

    private func isUsableCode(_ code: String) -> Bool {
        !code.isEmpty && !code.contains("$(")
    }

    @MainActor
    private func createAndCompleteTodo(app: XCUIApplication) {
        workTab(app: app).tap()
        let addButton = addWorkItemButton(app: app)
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), app.debugDescription)
        addButton.tap()

        type("todo-title-field", value: todoTitle, app: app)
        type("todo-notes-field", value: "Created from simulator \(runID)", app: app)

        app.buttons["todo-save-button"].tap()
        XCTAssertTrue(app.staticTexts[todoTitle].waitForExistence(timeout: 30), app.debugDescription)

        let completeButton = app.buttons["Mark complete"].firstMatch
        XCTAssertTrue(completeButton.waitForExistence(timeout: 10), app.debugDescription)
        completeButton.tap()

        let completedTodo = app.staticTexts[todoTitle]
        let removedFromOpenFilter = NSPredicate(format: "exists == false")
        expectation(for: removedFromOpenFilter, evaluatedWith: completedTodo)
        waitForExpectations(timeout: 20)
    }

    @MainActor
    private func createAndUpdateContact(app: XCUIApplication) {
        app.tabBars.buttons["People"].tap()
        let addButton = addPersonButton(app: app)
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), app.debugDescription)
        addButton.tap()

        type("contact-name-field", value: contactName, app: app)
        type("contact-company-field", value: "Simulator Verification", app: app)
        type("contact-email-field", value: "ios-\(runID)@\(verificationConfig.contactEmailDomain)", app: app)
        type("contact-phone-field", value: "+14165550100", app: app)
        type("contact-notes-field", value: "Created from simulator \(runID)", app: app)

        app.buttons["contact-save-button"].tap()

        filterPeople(for: contactName, app: app)
        XCTAssertTrue(app.staticTexts[contactName].waitForExistence(timeout: 30), app.debugDescription)
        app.staticTexts[contactName].tap()

        let editButton = editPersonButton(app: app)
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), app.debugDescription)
        editButton.tap()

        let notesField = element(identifier: "contact-notes-field", app: app)
        XCTAssertTrue(notesField.waitForExistence(timeout: 10), app.debugDescription)
        notesField.tap()
        notesField.typeText(" \(updatedContactNotes)")

        app.buttons["contact-save-button"].tap()
        XCTAssertTrue(app.navigationBars[contactName].waitForExistence(timeout: 20), app.debugDescription)
    }

    @MainActor
    private func chatWithAssistant(app: XCUIApplication) {
        app.tabBars.buttons["Chat"].tap()
        let newButton = newChatButton(app: app)
        XCTAssertTrue(newButton.waitForExistence(timeout: 10), app.debugDescription)
        newButton.tap()

        sendChatMessage(chatProbeText, app: app)
        waitForAssistantTurn(app: app)

        XCTAssertTrue(
            app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS %@", "What needs attention?"))
                .firstMatch
                .waitForExistence(timeout: 10),
            app.debugDescription
        )

        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Captured. Next best action")).firstMatch.exists,
            "Chat returned the local canned fallback instead of production assistant output."
        )
    }

    @MainActor
    private func workTab(app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Work", "Todos"))
            .firstMatch
    }

    @MainActor
    private func addWorkItemButton(app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Add work item", "Add Todo"))
            .firstMatch
    }

    @MainActor
    private func addPersonButton(app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Add person", "Add Person"))
            .firstMatch
    }

    @MainActor
    private func editPersonButton(app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Edit person", "Edit Person"))
            .firstMatch
    }

    @MainActor
    private func newChatButton(app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@", "New chat", "New Chat"))
            .firstMatch
    }

    @MainActor
    private func sendChatMessage(_ text: String, app: XCUIApplication) {
        let field = element(identifier: "chat-message-field", app: app)
        type(field, value: text, app: app, timeout: 20)

        let sendButton = app.buttons["chat-send-button"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10), app.debugDescription)
        sendButton.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func waitForAssistantTurn(app: XCUIApplication) {
        let pending = app.descendants(matching: .any)["chat-assistant-pending"]
        _ = pending.waitForExistence(timeout: 8)

        let field = element(identifier: "chat-message-field", app: app)
        let composerEnabled = NSPredicate(format: "enabled == true")
        expectation(for: composerEnabled, evaluatedWith: field)
        waitForExpectations(timeout: 160)
    }

    @MainActor
    private func filterPeople(for value: String, app: XCUIApplication) {
        let searchField = app.searchFields.firstMatch
        type(searchField, value: value, app: app)
    }

    @MainActor
    private func type(_ identifier: String, value: String, app: XCUIApplication) {
        let field = element(identifier: identifier, app: app)
        type(field, value: value, app: app)
    }

    @MainActor
    private func type(_ element: XCUIElement, value: String, app: XCUIApplication, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        element.tap()

        if !waitForKeyboardFocus(element, timeout: 1) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        XCTAssertTrue(waitForKeyboardFocus(element, timeout: 3), element.debugDescription)
        element.typeText(value)
    }

    @MainActor
    private func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hasFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: hasFocus, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func element(identifier: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
