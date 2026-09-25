/// Authenticated Messages relay; only the paired device can claim or acknowledge its commands.
import Foundation

extension MaraithonClient {
    func messageSendRequest<T: Decodable>(path: String, body: [String: BrowserJSON]) async throws -> T {
        var request = try await makeRequest(method: "POST", path: "/api/v1/companion/message-send" + path,
            body: JSONEncoder().encode(BrowserJSON.object(body)), extraHeaders: ["Content-Type": "application/json"])
        request.timeoutInterval = 15
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
