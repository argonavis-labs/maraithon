/// Life/work and contact review use the paired user's credential and preserve query parameters.
import Foundation
import AssistantProgressKit

extension MaraithonClient {
    func lifeContext(path: String, input: LifeWorkContext.Input?) async throws -> LifeWorkContext.Response {
        guard let components = URLComponents(string: path) else { throw MaraithonClientError.invalidResponse }
        let body = try input.map { try JSONEncoder().encode($0) }
        let request = try await makeRequest(method: input == nil ? "GET" : "POST",
            path: "/api/v1/companion/\(components.path)", body: body,
            queryItems: components.queryItems ?? [], extraHeaders: ["Content-Type": "application/json"])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(LifeWorkContext.Response.self, from: data)
    }
}
