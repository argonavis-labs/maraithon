/// Shared context review uses only the signed-in user's mobile API credential.
import Foundation
import AssistantProgressKit

extension MobileAPIClient {
    func lifeContext(sessionToken: String, path: String, input: LifeWorkContext.Input?) async throws -> LifeWorkContext.Response {
        let body = try input.map { try JSONDecoder().decode(RequestBody.self, from: JSONEncoder().encode($0)) }
        return try await send(path: path, method: input == nil ? "GET" : "POST", sessionToken: sessionToken,
            body: body, responseType: LifeWorkContext.Response.self)
    }
}
