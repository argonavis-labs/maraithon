/// Paired-device access to the existing durable assistant. Retries reuse client message IDs.
import Foundation

extension MaraithonClient {
    func todoConversation(id: String) async throws -> CompanionConversation.Response {
        try await conversationRequest(path: "/todos/\(id)/chat", method: "POST")
    }

    func conversation(id: String) async throws -> CompanionConversation.Response {
        try await conversationRequest(path: "/chat/threads/\(id)")
    }

    func sendConversationMessage(threadID: String, clientID: String, body: String) async throws -> CompanionConversation.Response {
        try await conversationRequest(path: "/chat/threads/\(threadID)/messages", method: "POST",
            body: JSONEncoder().encode(["message": ["client_message_id": clientID, "body": body]]))
    }

    func conversationRun(id: String) async throws -> CompanionConversation.Run {
        struct Response: Decodable { let run: CompanionConversation.Run }
        let response: Response = try await conversationRequest(path: "/chat/runs/\(id)")
        return response.run
    }

    func decideConversationAction(id: String, decision: String, edits: [String: String]) async throws -> CompanionConversation.Response {
        struct Decision: Encodable {
            let decision: String
            let client_message_id: String
            let draft_edits: [String: String]
        }
        return try await conversationRequest(path: "/chat/prepared-actions/\(id)/decision", method: "POST",
            body: JSONEncoder().encode(Decision(decision: decision, client_message_id: UUID().uuidString,
                draft_edits: edits)))
    }

    private func conversationRequest<T: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = try await makeRequest(method: method, path: "/api/v1/companion" + path,
            body: body, extraHeaders: ["Content-Type": "application/json"])
        request.timeoutInterval = 90
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
