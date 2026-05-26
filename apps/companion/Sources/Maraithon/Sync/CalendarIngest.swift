import Foundation

/// Calendar-specific HTTP client. Posts to
/// `POST /api/v1/companion/calendar-events` using the same auth +
/// transport shape as `MaraithonClient`, `NotesIngest`, and
/// `RemindersIngest`. We keep it as a separate type — same reasoning as
/// the sibling clients — because `SyncEngine` hard-codes the iMessage
/// `messages` field name and we don't want to grow that surface area
/// while the calendar contract is still settling.
///
/// Mutability story is identical to reminders: a calendar event's
/// title, start/end, attendees, and location can all change after first
/// sight (rescheduled meetings, accepted invites, location updates). The
/// server's `/calendar-events` endpoint upserts on
/// `(user_id, device_id, source, guid)`, so the source re-posts any
/// occurrence whose EventKit `lastModifiedDate` advanced past the
/// cursor.
struct CalendarIngest: Sendable {
    /// Closure invoked after a successful push so the source can be
    /// mirrored into Spotlight. See `NotesIngest.SpotlightHook` — same
    /// contract: best-effort, errors are swallowed by the caller.
    typealias SpotlightHook = @Sendable ([CalendarEventPayload]) async -> Void

    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    let path: String
    /// Optional realtime channel. Same fallback contract as
    /// `NotesIngest`: when connected, push lands instantly; otherwise
    /// fall through to HTTP.
    let realtime: RealtimeChannel?
    /// Optional Spotlight hook (see `SpotlightHook`).
    let spotlight: SpotlightHook?

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)",
        path: String = "/api/v1/companion/calendar-events",
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

    /// POST a calendar batch. Returns the server's accepted/duplicate
    /// counts so the source can log them. On transport / 5xx failures
    /// the source surfaces `.error` and the next poll cycle re-attempts
    /// the same batch — the cursor only advances after a 2xx response.
    func push(deviceId: UUID, events: [CalendarEventPayload]) async throws -> SyncOutcome {
        guard !events.isEmpty else {
            return SyncOutcome(accepted: 0, duplicate: 0)
        }
        let body = CalendarIngestBody(
            deviceId: deviceId,
            source: "calendar",
            calendarEvents: events
        )
        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: body)
                let outcome = try await realtime.push(
                    event: "ingest:calendar_events",
                    payload: payload
                )
                if let spotlight {
                    await spotlight(events)
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
            await spotlight(events)
        }
        return SyncOutcome(accepted: decoded.accepted, duplicate: decoded.duplicate)
    }

    /// Shared encoder configured to emit ISO-8601 dates. Centralised so
    /// future formatting tweaks (fractional seconds, etc.) live in one
    /// place.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Mirrors the HTTP encoder so the realtime channel ships the exact
    /// same wire shape.
    private static func realtimePayload(from body: CalendarIngestBody) throws -> [String: Any] {
        let data = try encoder.encode(body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

/// Per-event payload. Matches the server contract field names via
/// `CodingKeys`. All "user content" fields (`title`, `notes`,
/// `calendarName`, `location`, `organizerEmail`) are nullable on the
/// wire so the server can distinguish "missing" from "empty string".
///
/// `attendeeEmails` is always present but may be empty — the server
/// stores `[]` on the row, which keeps downstream filtering on
/// "events with attendee X" simple.
struct CalendarEventPayload: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let calendarName: String?
    let calendarColor: String?
    let title: String?
    let notes: String?
    let location: String?
    let startAt: Date
    let endAt: Date
    let isAllDay: Bool
    let isRecurring: Bool
    let organizerEmail: String?
    let attendeesCount: Int
    let attendeeEmails: [String]
    let createdAt: Date?
    let modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case calendarName = "calendar_name"
        case calendarColor = "calendar_color"
        case title
        case notes
        case location
        case startAt = "start_at"
        case endAt = "end_at"
        case isAllDay = "is_all_day"
        case isRecurring = "is_recurring"
        case organizerEmail = "organizer_email"
        case attendeesCount = "attendees_count"
        case attendeeEmails = "attendee_emails"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

/// Envelope of the full request body — kept private so callers only
/// ever see a typed `[CalendarEventPayload]`.
private struct CalendarIngestBody: Codable, Sendable {
    let deviceId: UUID
    let source: String
    let calendarEvents: [CalendarEventPayload]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case calendarEvents = "calendar_events"
    }
}
