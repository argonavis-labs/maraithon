/// Mac assistant settings share their form and validation with iPhone and web.
import SwiftUI
import AssistantProgressKit

struct DelegationSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        AssistantSettingsView(webURL: URL(string: "/settings/assistant", relativeTo: MaraithonClient.defaultBaseURL)) { path, fields in
            let auth = env.deviceAuth
            let client = MaraithonClient(tokenProvider: { [weak auth] in
                await MainActor.run { [auth] in auth?.currentToken }
            })
            return try await client.assistantSettings(path: path, fields: fields)
        }
        .id(env.deviceAuth.currentToken)
    }
}
