/// Native account settings use the paired device's user, never a request-selected owner.
import SwiftUI
import AssistantProgressKit

struct AccountSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        AccountCategoriesView { id, category in
            let auth = env.deviceAuth
            let client = MaraithonClient(tokenProvider: { [weak auth] in
                await MainActor.run { [auth] in auth?.currentToken }
            })
            let response = try await client.accountCategories(id: id, category: category)
            if id != nil { await env.todos.load() }
            return response
        }
    }
}
