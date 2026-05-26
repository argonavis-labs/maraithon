import Foundation

/// Reminders-specific HTTP client. Posts to
/// `POST /api/v1/companion/reminders` using the same auth + transport
/// shape as `MaraithonClient` and `NotesIngest`. We keep it as a
/// separate type — same reasoning as the notes / voice-memos clients —
/// because `SyncEngine` hard-codes the iMessage `messages` field name
/// and we don't want to grow that surface area while the reminders
/// contract is still settling.
///
/// Mutability differs from notes and voice memos: a reminder's
/// completion state, title, and due date can all change after first
/// sight. The server's `/reminders` endpoint upserts on
/// `(user_id, device_id, source, guid)`, so the source can simply
/// re-post any reminder whose EventKit `lastModifiedDate` advanced
/// past the cursor — the server overwrites the matching row.
struct RemindersIngest: Sendable {
    /// Closure invoked after a successful push so the source can be
    /// mirrored into Spotlight. See `NotesIngest.SpotlightHook` — same
    /// contract: best-effort, errors are swallowed by the caller.
    typealias SpotlightHook = @Sendable ([ReminderPayload]) async -> Void

    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    let path: String
    /// Optional realtime channel. Same fallback contract as
    /// `NotesIngest`.
    let realtime: RealtimeChannel?
    /// Optional Spotlight hook (see `SpotlightHook`).
    let spotlight: SpotlightHook?

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)",
        path: String = "/api/v1/companion/reminders",
        realtime: RealtimeChannel? = nil,
        spotlight: SpotlightHook? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
        self.path = path
        self.realtime = realtime
        self.spotlight = spotlight
    }

    /// POST a reminders batch. On transport / 5xx failures the source
    /// surfaces `.error` through its status publisher and the next
    /// poll cycle re-attempts the same batch — the cursor only
    /// advances after a 2xx response.
    func push(deviceId: UUID, reminders: [ReminderPayload]) async throws -> SyncOutcome {
        guard !reminders.isEmpty else {
            return SyncOutcome(accepted: 0, duplicate: 0)
        }
        let body = RemindersIngestBody(
            deviceId: deviceId,
            source: "reminders",
            reminders: reminders
        )
        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: body)
                let outcome = try await realtime.push(event: "ingest:reminders", payload: payload)
                if let spotlight {
                    await spotlight(reminders)
                }
                return SyncOutcome(accepted: outcome.accepted, duplicate: outcome.duplicate)
            } catch is RealtimeChannel.RealtimeChannelError {
                // Any realtime-channel failure falls back to HTTP. The
                // channel is best-effort; HTTP is the reliable transport.
                // This includes `serverError(reason:)` cases like
                // "unmatched topic" the server emits when its channel
                // state diverges from ours after a reconnect.
            }
        }
        let bodyData = try Self.encoder.encode(body)
        let gzipped = try Gzip.compress(bodyData)

        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: path)
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
            break
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
        let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
        if let spotlight {
            await spotlight(reminders)
        }
        return SyncOutcome(accepted: decoded.accepted, duplicate: decoded.duplicate)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Mirrors the HTTP encoder so the realtime channel ships the exact
    /// same wire shape.
    private static func realtimePayload(from body: RemindersIngestBody) throws -> [String: Any] {
        let data = try encoder.encode(body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

/// Per-reminder payload. Matches the server contract field names via
/// `CodingKeys`. All "user content" fields (`title`, `notes`,
/// `listName`, `urlAttachment`) are nullable on the wire so the server
/// can tell "missing" apart from "empty string".
///
/// `priority` follows EventKit's convention: `0` is "no priority", `1`
/// is highest, `9` is lowest. We pass the raw integer through and let
/// the server bucket it.
struct ReminderPayload: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let title: String?
    let notes: String?
    let listName: String?
    let listColor: String?
    let priority: Int
    let dueAt: Date?
    let completedAt: Date?
    let isCompleted: Bool
    let hasAlarm: Bool
    let urlAttachment: String?
    let createdAt: Date?
    let modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case title
        case notes
        case listName = "list_name"
        case listColor = "list_color"
        case priority
        case dueAt = "due_at"
        case completedAt = "completed_at"
        case isCompleted = "is_completed"
        case hasAlarm = "has_alarm"
        case urlAttachment = "url_attachment"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

/// Envelope of the full request body — kept private so callers only
/// ever see a typed `[ReminderPayload]`.
private struct RemindersIngestBody: Codable, Sendable {
    let deviceId: UUID
    let source: String
    let reminders: [ReminderPayload]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case reminders
    }
}
