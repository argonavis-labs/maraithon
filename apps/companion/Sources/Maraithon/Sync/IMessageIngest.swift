import Foundation

/// iMessage-specific HTTP client. Mirrors `NotesIngest` /
/// `RemindersIngest` etc. — a typed batch + a thin POST helper, with
/// realtime-channel-first / HTTP-fallback semantics.
///
/// Historical context: iMessage shipped first and routed through the
/// generic `SyncEngine` + `SyncEnvelope` (everything nested under
/// `payload`). The server contract reads top-level fields per message
/// (`text`, `local_id`, `sent_at`, …), so the inner `payload` map was
/// dropped on the server floor — every column except `source` / `guid` /
/// boolean defaults landed as NULL. This helper sends a typed, top-level
/// shape (matching the server's expectations and the contract the other
/// sources use) so message bodies actually persist.
struct IMessageIngest: Sendable {
    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    /// Optional realtime channel. When provided **and** connected,
    /// `ingestMessages` pushes through the channel first; any channel-
    /// side error falls back to HTTP.
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

    /// POST a messages batch. Realtime-first with HTTP fallback, same
    /// pattern as `NotesIngest.ingestNotes`. The cursor only advances
    /// after a successful response so dup-batches are de-duped by the
    /// server's `(user_id, device_id, source, guid)` constraint.
    func ingestMessages(batch: IMessageIngestBatch) async throws -> SyncOutcome {
        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: batch)
                let outcome = try await realtime.push(
                    event: "ingest:messages",
                    payload: payload
                )
                return SyncOutcome(
                    accepted: outcome.accepted,
                    duplicate: outcome.duplicate,
                    invalid: outcome.invalid
                )
            } catch is RealtimeChannel.RealtimeChannelError {
                // Any realtime-channel failure falls back to HTTP. The
                // channel is best-effort; HTTP is the reliable transport.
            }
        }
        return try await httpIngest(batch: batch)
    }

    private func httpIngest(batch: IMessageIngestBatch) async throws -> SyncOutcome {
        let bodyData = try Self.encoder.encode(batch)
        let gzipped = try Gzip.compress(bodyData)
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: "/api/v1/companion/messages")
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
            let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
            return SyncOutcome(accepted: decoded.accepted, duplicate: decoded.duplicate, invalid: decoded.invalid)
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

    /// Round-trips the `Codable` representation so the realtime channel
    /// ships the exact same key shape the HTTP path uses.
    private static func realtimePayload(from batch: IMessageIngestBatch) throws -> [String: Any] {
        let data = try encoder.encode(batch)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Wire body for `POST /api/v1/companion/messages` and the
/// `ingest:messages` realtime event. Typed end-to-end (no `AnyCodable`
/// wrapping) so every field lands as a top-level key the server's
/// `fetch/2` can find.
struct IMessageIngestBatch: Codable, Sendable, Equatable {
    let deviceId: UUID
    let source: String
    let messages: [MessageRecord]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case messages
    }
}

/// One iMessage as posted to the server. Field names match the
/// `Maraithon.LocalMessages.LocalMessage` schema's column names so each
/// value lands in the right column without the server unpacking a
/// nested map.
struct MessageRecord: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let isFromMe: Bool
    let senderHandle: String?
    let chatKey: String?
    let chatDisplayName: String?
    let chatStyle: String?
    let text: String?
    let sentAt: String?
    let hasAttachments: Bool
    /// JSON-encoded array of chat participant handles. Server stores
    /// them in the `attachments`/related metadata; the inline JSON
    /// string preserves the legacy wire-shape on read.
    let chatHandlesJSON: String?
    /// JSON-encoded attachments. Today always `"[]"` until attachment
    /// extraction lands.
    let attachmentsJSON: String?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case isFromMe = "is_from_me"
        case senderHandle = "sender_handle"
        case chatKey = "chat_key"
        case chatDisplayName = "chat_display_name"
        case chatStyle = "chat_style"
        case text
        case sentAt = "sent_at"
        case hasAttachments = "has_attachments"
        case chatHandlesJSON = "chat_handles_json"
        case attachmentsJSON = "attachments_json"
    }
}
