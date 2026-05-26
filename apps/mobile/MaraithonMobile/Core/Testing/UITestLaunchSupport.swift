#if DEBUG
import Foundation
import SwiftData

@MainActor
enum UITestLaunchSupport {
    private enum EnvironmentKeys {
        static let resetState = "MARAITHON_UI_TEST_RESET_STATE"
        static let magicToken = "MARAITHON_UI_TEST_MAGIC_TOKEN"
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
        let token = ProcessInfo.processInfo.environment[EnvironmentKeys.magicToken]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let token, !token.isEmpty else { return }
        await sessionStore.consumeMagicLink(token)
    }
}
#endif
