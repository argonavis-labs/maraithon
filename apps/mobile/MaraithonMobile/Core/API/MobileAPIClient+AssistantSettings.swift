/// Uses the shared mobile API root once, with the signed-in user's settings only.
import Foundation
import AssistantProgressKit

extension MobileAPIClient {
    func assistantSettings(sessionToken: String, path: String,
                           fields: [String: AssistantSettings.Value]?) async throws -> AssistantSettings.Response {
        let body = try fields.map { try JSONDecoder().decode(RequestBody.self, from: JSONEncoder().encode($0)) }
        return try await send(path: path, method: fields == nil ? "GET" : "POST", sessionToken: sessionToken,
            body: body, responseType: AssistantSettings.Response.self)
    }
}
