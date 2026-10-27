/// Context sheets are bound to the current session and discard their drafts on account changes.
import SwiftUI
import AssistantProgressKit

struct LifeContextSheet: View {
    @Environment(SessionStore.self) private var sessionStore
    var person: LifeWorkContext.PersonReference?
    var saved: @MainActor () async -> Void = {}

    var body: some View {
        Group {
            if let person { PersonReviewView(reference: person, request: request, saved: saved) }
            else { LifeWorkContextView(request: request) }
        }
        .id(sessionStore.user?.id)
    }

    private func request(_ path: String, _ input: LifeWorkContext.Input?) async throws -> LifeWorkContext.Response {
        guard let token = sessionStore.user?.sessionToken else { throw MobileAPIError.unauthorized }
        let result = try await MobileAPIClient().lifeContext(sessionToken: token, path: path, input: input)
        guard sessionStore.user?.sessionToken == token else { throw CancellationError() }
        return result
    }
}
