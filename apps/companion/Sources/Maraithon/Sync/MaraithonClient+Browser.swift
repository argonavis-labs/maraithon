/// Browser relay uses the existing device token; no local debugging endpoint leaves the Mac.
import Foundation

extension MaraithonClient {
    func browserRequest<T: Decodable>(path: String, body: [String: BrowserJSON]) async throws -> T {
        let data = try JSONEncoder().encode(BrowserJSON.object(body))
        var request = try await makeRequest(method: "POST", path: "/api/v1/companion/browser" + path,
            body: data, extraHeaders: ["Content-Type": "application/json"])
        request.timeoutInterval = 15
        let (responseData, response) = try await transport(request)
        try Self.validate(response: response, data: responseData)
        return try JSONDecoder().decode(T.self, from: responseData)
    }
}
