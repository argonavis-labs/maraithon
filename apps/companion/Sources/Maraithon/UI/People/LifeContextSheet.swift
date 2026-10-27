/// Native context sheets share the same paired-device authentication and explicit review flow.
import SwiftUI
import AssistantProgressKit

struct LifeContextSheet: View {
    @Environment(AppEnvironment.self) private var env
    var person: LifeWorkContext.PersonReference?
    var saved: @MainActor () async -> Void = {}

    var body: some View {
        Group {
            if let person { PersonReviewView(reference: person, request: request, saved: saved) }
            else { LifeWorkContextView(request: request) }
        }
    }

    private func request(_ path: String, _ input: LifeWorkContext.Input?) async throws -> LifeWorkContext.Response {
        let auth = env.deviceAuth
        let client = MaraithonClient(tokenProvider: { await auth.currentToken })
        do { return try await client.lifeContext(path: path, input: input) }
        catch MaraithonClientError.unauthorized {
            auth.tokenRejected()
            throw MaraithonClientError.unauthorized
        }
    }
}
