import AssistantProgressKit
import Foundation

extension MobileChatAPI {
    func observeChatProgress(sessionToken: String, id: UUID, cursor: String?,
        onEvent: @escaping @MainActor @Sendable (AssistantProgress<MobileAPIClient.RemoteChatThread>) async throws -> Void
    ) async throws {
        throw AssistantProgressStream.Failure.httpStatus(501)
    }
}

extension MobileAPIClient {
    func observeChatProgress(sessionToken: String, id: UUID, cursor: String?,
        onEvent: @escaping @MainActor @Sendable (AssistantProgress<RemoteChatThread>) async throws -> Void
    ) async throws {
        let url = baseURL.appending(path: "chat/threads/\(id.uuidString)/events")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = MobileAPIClient.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
            }
            return date
        }
        do {
            try await AssistantProgressStream.observe(request: request, decoder: decoder, onEvent: onEvent)
        } catch AssistantProgressStream.Failure.httpStatus(401) {
            await MainActor.run { Self.unauthorizedHandler?() }
            throw MobileAPIError.unauthorized
        }
    }
}
