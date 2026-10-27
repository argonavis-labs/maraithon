import AssistantProgressKit
import Foundation

extension MaraithonClient {
    func observeConversation(id: String, cursor: String?,
        onEvent: @Sendable (AssistantProgress<CompanionConversation>) async throws -> Void
    ) async throws {
        let headers = cursor.map { ["Last-Event-ID": $0] } ?? [:]
        let request = try await makeRequest(method: "GET",
            path: "/api/v1/companion/chat/threads/\(id)/events", body: nil, extraHeaders: headers)
        try await AssistantProgressStream.observe(request: request, decoder: JSONDecoder(), onEvent: onEvent)
    }
}
