/// Settings reads and updates preserve query parameters and paired-device authentication.
import Foundation
import AssistantProgressKit

extension MaraithonClient {
    func assistantSettings(path: String, fields: [String: AssistantSettings.Value]?) async throws -> AssistantSettings.Response {
        guard let components = URLComponents(string: path) else { throw MaraithonClientError.invalidResponse }
        let body = try fields.map { try JSONEncoder().encode($0) }
        let request = try await makeRequest(method: fields == nil ? "GET" : "POST",
            path: "/api/v1/companion/\(components.path)", body: body,
            queryItems: components.queryItems ?? [], extraHeaders: ["Content-Type": "application/json"])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(AssistantSettings.Response.self, from: data)
    }
}
