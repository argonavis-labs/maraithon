import XCTest

final class ProductionIntegrationUITests: XCTestCase {
    private struct VerificationConfig: Decodable {
        let magicToken: String
        let runID: String
        let contactEmailDomain: String
    }

    private var verificationConfig: VerificationConfig!

    private var runID: String {
        verificationConfig?.runID ?? "manual"
    }

    private var todoTitle: String {
        "iOS prod todo \(runID)"
    }

    private var contactName: String {
        "iOS Prod Person \(runID)"
    }

    private var updatedContactNotes: String {
        "Updated from simulator \(runID)"
    }

    private var chatProbeText: String {
        "Say mobile verification \(runID) in one sentence."
    }

    @MainActor
    func testProductionMagicSigninTodoAndPeoplePersistence() throws {
        continueAfterFailure = false
        verificationConfig = loadVerificationConfig()
        guard isUsableToken(verificationConfig.magicToken) else { return }
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Todos"].waitForExistence(timeout: 60), app.debugDescription)

        createAndCompleteTodo(app: app)
        createAndUpdateContact(app: app)
        chatWithAssistant(app: app)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let magicToken = verificationConfig.magicToken
        XCTAssertFalse(magicToken.isEmpty, "MARAITHON_MAGIC_TOKEN must contain a fresh production magic-link token.")

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launchEnvironment["MARAITHON_UI_TEST_MAGIC_TOKEN"] = magicToken
        app.launchEnvironment["MARAITHON_UI_TEST_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    private func loadVerificationConfig() -> VerificationConfig {
        let environment = ProcessInfo.processInfo.environment
        let environmentToken = environment["MARAITHON_MAGIC_TOKEN"] ?? ""
        let contactEmailDomain = environment["MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN"] ?? ""
        XCTAssertTrue(
            isUsableToken(environmentToken),
            "MARAITHON_MAGIC_TOKEN must be passed through the test scheme as a fresh production token."
        )
        XCTAssertFalse(
            contactEmailDomain.isEmpty,
            "MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN must be passed through the test scheme."
        )

        return VerificationConfig(
            magicToken: environmentToken,
            runID: environment["MARAITHON_VERIFY_RUN_ID"] ?? "manual",
            contactEmailDomain: contactEmailDomain
        )
    }

    private func isUsableToken(_ token: String) -> Bool {
        !token.isEmpty && !token.contains("$(")
    }

    @MainActor
    private func createAndCompleteTodo(app: XCUIApplication) {
        app.tabBars.buttons["Todos"].tap()
        app.buttons["Add Todo"].tap()

        let titleField = app.textFields["todo-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), app.debugDescription)
        titleField.tap()
        titleField.typeText(todoTitle)

        let notesField = app.textFields["todo-notes-field"]
        XCTAssertTrue(notesField.waitForExistence(timeout: 5), app.debugDescription)
        notesField.tap()
        notesField.typeText("Created from simulator \(runID)")

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
        app.buttons["Add Person"].tap()

        type("contact-name-field", value: contactName, app: app)
        type("contact-company-field", value: "Simulator Verification", app: app)
        type("contact-email-field", value: "ios-\(runID)@\(verificationConfig.contactEmailDomain)", app: app)
        type("contact-phone-field", value: "+14165550100", app: app)
        type("contact-notes-field", value: "Created from simulator \(runID)", app: app)

        app.buttons["contact-save-button"].tap()

        filterPeople(for: contactName, app: app)
        XCTAssertTrue(app.staticTexts[contactName].waitForExistence(timeout: 30), app.debugDescription)
        app.staticTexts[contactName].tap()

        let editButton = app.buttons["Edit Person"]
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
        app.buttons["New Chat"].firstMatch.tap()

        sendChatMessage(chatProbeText, app: app)
        waitForAssistantTurn(app: app)

        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Captured. Next best action")).firstMatch.exists,
            "Chat returned the local canned fallback instead of production assistant output."
        )
    }

    @MainActor
    private func sendChatMessage(_ text: String, app: XCUIApplication) {
        let field = element(identifier: "chat-message-field", app: app)
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        field.tap()
        field.typeText(text)

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
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), app.debugDescription)
        searchField.tap()
        searchField.typeText(value)
    }

    @MainActor
    private func type(_ identifier: String, value: String, app: XCUIApplication) {
        let field = element(identifier: identifier, app: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText(value)
    }

    @MainActor
    private func element(identifier: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
