import AssistantProgressKit
import Foundation

/// Delegation requests retain the server's expected revision and retry identity.
extension MobileAPIClient {
    func delegationRequest(sessionToken: String, path: String,
                           input: TodoDelegation.Request?) async throws -> TodoDelegation.Response {
        let body = try input.map {
            try JSONDecoder().decode(RequestBody.self, from: JSONEncoder().encode($0))
        }
        return try await send(path: "/\(path)", method: input == nil ? "GET" : "POST",
            sessionToken: sessionToken, body: body, responseType: TodoDelegation.Response.self)
    }
}
