#if DEBUG
import Foundation
import SwiftData

@MainActor
enum UITestLaunchSupport {
    private enum EnvironmentKeys {
        static let resetState = "MARAITHON_UI_TEST_RESET_STATE"
        static let magicToken = "MARAITHON_UI_TEST_MAGIC_TOKEN"
        static let magicCode = "MARAITHON_UI_TEST_MAGIC_CODE"
        static let startTab = "MARAITHON_UI_TEST_START_TAB"
        static let skipPush = "MARAITHON_UI_TEST_SKIP_PUSH"
    }

    /// Design-review launches skip the push permission prompt so screenshots
    /// are not covered by the system alert.
    static var skipsPushPrompt: Bool {
        ProcessInfo.processInfo.environment[EnvironmentKeys.skipPush] == "1"
    }

    /// Design-review launches can open on a specific tab
    /// (`today`, `todos`, `people`, `chat`).
    static func requestedStartTab() -> AppTab? {
        switch ProcessInfo.processInfo.environment[EnvironmentKeys.startTab] {
        case "today": return .today
        case "todos": return .todos
        case "people": return .people
        case "chat": return .chat
        default: return nil
        }
    }

    static func resetStateIfNeeded(modelContext: ModelContext) {
        guard ProcessInfo.processInfo.environment[EnvironmentKeys.resetState] == "1" else {
            return
        }

        UserDefaults.standard.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)

        do {
            for message in try modelContext.fetch(FetchDescriptor<ChatMessage>()) {
                modelContext.delete(message)
            }
            for thread in try modelContext.fetch(FetchDescriptor<ChatThread>()) {
                modelContext.delete(thread)
            }
            for todo in try modelContext.fetch(FetchDescriptor<TodoItem>()) {
                modelContext.delete(todo)
            }
            for contact in try modelContext.fetch(FetchDescriptor<CRMContact>()) {
                modelContext.delete(contact)
            }
            try modelContext.save()
        } catch {
            assertionFailure("Unable to reset UI test state: \(error)")
        }
    }

    static func consumeMagicLinkIfNeeded(sessionStore: SessionStore) async {
        let code = ProcessInfo.processInfo.environment[EnvironmentKeys.magicCode]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let code, !code.isEmpty {
            await sessionStore.consumeMagicLink(code)
            return
        }

        let token = ProcessInfo.processInfo.environment[EnvironmentKeys.magicToken]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let token, !token.isEmpty else { return }
        await sessionStore.consumeMagicLink(token)
    }
}
#endif
