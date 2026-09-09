import Foundation

public enum AssistantProgressStream {
    public enum Failure: Error, Sendable {
        case httpStatus(Int)
        case invalidResponse
        case unsupportedVersion
        case frameTooLarge
    }

    /// Ends after one bounded connection. The caller owns retry/backoff and
    /// advances its cursor only after successfully applying a snapshot.
    public static func observe<Thread: Decodable & Sendable>(
        request: URLRequest,
        decoder: JSONDecoder,
        onEvent: @Sendable (AssistantProgress<Thread>) async throws -> Void
    ) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 65
        config.timeoutIntervalForResource = 70
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = request
        request.timeoutInterval = 65
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode == 200 else { throw Failure.httpStatus(http.statusCode) }
        guard http.mimeType == "text/event-stream" else { throw Failure.invalidResponse }
        var parser = SSEFrameParser()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let frame = try parser.append(byte) else { continue }
            switch frame.event {
            case "snapshot":
                let snapshot = try decoder.decode(AssistantProgress<Thread>.Snapshot.self, from: frame.data)
                guard snapshot.schemaVersion == 1 else { throw Failure.unsupportedVersion }
                guard snapshot.cursor == frame.id, !snapshot.cursor.isEmpty else { throw Failure.invalidResponse }
                try await onEvent(.snapshot(snapshot))
            case "preview":
                let preview = try decoder.decode(AssistantProgress<Thread>.Preview.self, from: frame.data)
                guard preview.schemaVersion == 1 else { throw Failure.unsupportedVersion }
                try await onEvent(.preview(preview))
            default: continue
            }
        }
        try Task.checkCancellation()
    }
}
