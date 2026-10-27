/// Account category changes use the shared server contract and paired-device authentication.
import Foundation
import AssistantProgressKit

extension MaraithonClient {
    func accountCategories(id: Int?, category: String?) async throws -> AccountCategoriesView.Response {
        let path = "/api/v1/companion/account-categories" + (id.map { "/\($0)" } ?? "")
        let body = try category.map { try JSONEncoder().encode(["category": $0]) }
        let request = try await makeRequest(method: id == nil ? "GET" : "POST", path: path,
            body: body, extraHeaders: ["Content-Type": "application/json"])
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(AccountCategoriesView.Response.self, from: data)
    }
}
