import Foundation

/// HTTP client for `POST /api/v1/companion/browser-history`. Mirrors
/// `NotesIngest` and `VoiceMemosIngest`. Kept as a separate type so the
/// shared `MaraithonClient` and `SyncEngine` don't grow new surface
/// area while the browser-history server contract is still landing.
struct BrowserHistoryIngest: Sendable {
    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    /// Optional realtime channel. Same fallback contract as
    /// `NotesIngest`. The browser-history payload is also the one
    /// case where the channel reply has all four counter fields
    /// (`accepted`, `duplicate`, `invalid`, `filtered`).
    let realtime: RealtimeChannel?

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)",
        realtime: RealtimeChannel? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
        self.realtime = realtime
    }

    /// POST a browser-history batch. Response shape:
    /// `{ "accepted": N, "duplicate": M, "invalid": K, "filtered": F }`.
    func ingestVisits(batch: BrowserHistoryIngestBatch) async throws -> BrowserHistoryIngestOutcome {
        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: batch)
                let outcome = try await realtime.push(
                    event: "ingest:browser_history",
                    payload: payload
                )
                return BrowserHistoryIngestOutcome(
                    accepted: outcome.accepted,
                    duplicate: outcome.duplicate,
                    invalid: outcome.invalid,
                    filtered: outcome.filtered
                )
            } catch is RealtimeChannel.RealtimeChannelError {
                // Any realtime-channel failure falls back to HTTP. The
                // channel is best-effort; HTTP is the reliable transport.
                // This includes `serverError(reason:)` cases like
                // "unmatched topic" the server emits when its channel
                // state diverges from ours after a reconnect.
            }
        }
        let bodyData = try JSONEncoder().encode(batch)
        let gzipped = try Gzip.compress(bodyData)
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: "/api/v1/companion/browser-history")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = gzipped

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw MaraithonClientError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            let decoded = try JSONDecoder().decode(BrowserHistoryIngestResponse.self, from: data)
            return BrowserHistoryIngestOutcome(
                accepted: decoded.accepted,
                duplicate: decoded.duplicate,
                invalid: decoded.invalid ?? 0,
                filtered: decoded.filtered ?? 0
            )
        case 401:
            throw MaraithonClientError.unauthorized
        case 400..<500:
            throw MaraithonClientError.clientError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        default:
            throw MaraithonClientError.serverError(status: http.statusCode)
        }
    }

    /// Mirrors the HTTP encoder so the realtime channel ships the exact
    /// same wire shape.
    private static func realtimePayload(from batch: BrowserHistoryIngestBatch) throws
        -> [String: Any]
    {
        let data = try JSONEncoder().encode(batch)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

/// Wire body for `POST /api/v1/companion/browser-history`. Typed
/// end-to-end like `NotesIngestBatch`.
struct BrowserHistoryIngestBatch: Codable, Sendable, Equatable {
    let deviceId: UUID
    let source: String
    let visits: [BrowserVisitRecord]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case visits
    }
}

/// Server response. `invalid` and `filtered` are optional so an older
/// server that doesn't emit them still decodes cleanly.
struct BrowserHistoryIngestResponse: Codable, Sendable {
    let accepted: Int
    let duplicate: Int
    let invalid: Int?
    let filtered: Int?
}

/// Caller-facing outcome — every field always non-nil so source code
/// doesn't have to branch on the wire optionality.
struct BrowserHistoryIngestOutcome: Sendable, Equatable {
    let accepted: Int
    let duplicate: Int
    let invalid: Int
    let filtered: Int
}
