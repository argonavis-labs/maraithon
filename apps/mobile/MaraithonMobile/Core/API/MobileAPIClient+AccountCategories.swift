/// Account settings always use the authenticated session's user.
import Foundation
import AssistantProgressKit

extension MobileAPIClient {
    func accountCategories(sessionToken: String, id: Int?, category: String?) async throws -> AccountCategoriesView.Response {
        let path = "/account-categories" + (id.map { "/\($0)" } ?? "")
        return try await send(path: path, method: id == nil ? "GET" : "POST", sessionToken: sessionToken,
            body: category.map { ["category": .string($0)] }, responseType: AccountCategoriesView.Response.self)
    }
}
