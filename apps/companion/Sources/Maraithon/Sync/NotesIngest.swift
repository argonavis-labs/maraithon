import Foundation

/// Notes-specific HTTP client. Posts to `POST /api/v1/companion/notes`
/// using the same auth + transport shape as `MaraithonClient`, but kept
/// as a separate type so the iMessage-owned client doesn't grow new
/// surface area while the Notes server contract is still settling.
///
/// Design choice (per the Notes-team brief): rather than threading the
/// notes payload through `SyncEngine.enqueue` / `drain` — which today
/// hard-codes the `IngestBatch.messages` field name — we POST directly.
/// The trade-off: notes don't get the durable-queue retry that the
/// engine provides for iMessage. The `NotesSource` mitigates this by
/// only advancing its cursor after the POST returns success, so the
/// next poll re-tries the same batch on failure. Once the engine grows
/// a generic `enqueue(source:envelopes:)` we can fold this back in.
struct NotesIngest: Sendable {
    /// Closure invoked once a notes batch has been successfully posted
    /// (either via the realtime channel or HTTP fallback). The brief
    /// requires that we mirror every successful batch into the macOS
    /// Spotlight index; rather than threading a `SpotlightIndexer`
    /// reference through the source layer, we let the ingest helper
    /// own the hook so the call site stays one line.
    ///
    /// Hook failures are swallowed by the helper invocation — a
    /// Spotlight indexing miss must never fail the underlying sync.
    typealias SpotlightHook = @Sendable ([NoteRecord]) async -> Void

    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    /// Optional realtime channel. When provided **and** connected,
    /// `ingestNotes` pushes through the channel before falling back to
    /// HTTP. Default `nil` keeps every existing call site using POST.
    let realtime: RealtimeChannel?
    /// Optional Spotlight hook (see `SpotlightHook`). Default `nil`
    /// preserves the pre-Spotlight call-site shape.
    let spotlight: SpotlightHook?

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)",
        realtime: RealtimeChannel? = nil,
        spotlight: SpotlightHook? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
        self.realtime = realtime
        self.spotlight = spotlight
    }

    /// POST a notes batch. Mirrors `MaraithonClient.ingest(batch:)` so a
    /// future merge into the shared client is straightforward.
    ///
    /// When a connected `RealtimeChannel` is configured we push through
    /// the channel first; only a channel-side failure falls back to the
    /// HTTP path. The cursor only advances after a successful response
    /// from whichever transport delivered the batch, so duplicated
    /// posts across a channel-then-HTTP retry are de-duped by the
    /// server's `(user_id, device_id, source, guid)` constraint.
    func ingestNotes(batch: NotesIngestBatch) async throws -> SyncOutcome {
        let outcome: SyncOutcome
        if let realtime, await realtime.isConnected {
            do {
                let rt = try await realtime.push(
                    event: "ingest:notes",
                    payload: try Self.realtimePayload(from: batch)
                )
                outcome = SyncOutcome(accepted: rt.accepted, duplicate: rt.duplicate)
                if let spotlight {
                    await spotlight(batch.notes)
                }
                return outcome
            } catch is RealtimeChannel.RealtimeChannelError {
                // Any realtime-channel failure falls back to HTTP. The
                // channel is best-effort; HTTP is the reliable transport.
                // This includes `serverError(reason:)` cases like
                // "unmatched topic" the server emits when its channel
                // state diverges from ours after a reconnect.
            }
        }
        outcome = try await httpIngest(batch: batch)
        if let spotlight {
            await spotlight(batch.notes)
        }
        return outcome
    }

    private func httpIngest(batch: NotesIngestBatch) async throws -> SyncOutcome {
        let bodyData = try JSONEncoder().encode(batch)
        let gzipped = try Gzip.compress(bodyData)
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: "/api/v1/companion/notes")
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
            // The server agent confirmed the response shape mirrors the
            // messages endpoint — `{ "accepted": N, "duplicate": M }`.
            let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
            return SyncOutcome(accepted: decoded.accepted, duplicate: decoded.duplicate)
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

    /// Renders the wire body as a `[String: Any]` so the realtime
    /// channel can ship it through `JSONSerialization`. Round-trips the
    /// `Codable` representation so the field names match exactly what
    /// the HTTP path sends (snake_case, etc.).
    private static func realtimePayload(from batch: NotesIngestBatch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(batch)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

/// Wire body for `POST /api/v1/companion/notes`. Typed end-to-end (no
/// `AnyCodable` wrapping) because Notes started after the messages
/// endpoint and we don't need to thread it through `SyncEnvelope`'s
/// scalar-only payload bag.
struct NotesIngestBatch: Codable, Sendable, Equatable {
    let deviceId: UUID
    let source: String
    let notes: [NoteRecord]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case notes
    }
}

/// One note as posted to the server. Field shapes lifted from the
/// agreed contract in the Notes-team brief.
///
/// `body` is the decoded plain-text body recovered from the
/// `ZICNOTEDATA.ZDATA` Protocol Buffer; `bodyFormat` is the encoding
/// marker the server stores alongside it. Today the only value we
/// ship is `"plain"`, but the field exists so future RTF / Markdown
/// payloads don't need a wire-shape change.
struct NoteRecord: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let title: String?
    let snippet: String?
    let body: String?
    let bodyFormat: String?
    let folder: String?
    let isPinned: Bool
    let createdAt: String?
    let modifiedAt: String?
    /// Optional on-device summary of `body`. Generated client-side by
    /// ``OnDeviceSummarizer`` when the body is long enough to benefit
    /// from compaction. Kept additive on the wire so older servers
    /// ignore it cleanly.
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case title
        case snippet
        case body
        case bodyFormat = "body_format"
        case folder
        case isPinned = "is_pinned"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case summary
    }

    init(
        guid: String,
        localId: String,
        title: String?,
        snippet: String?,
        body: String?,
        bodyFormat: String?,
        folder: String?,
        isPinned: Bool,
        createdAt: String?,
        modifiedAt: String?,
        summary: String? = nil
    ) {
        self.guid = guid
        self.localId = localId
        self.title = title
        self.snippet = snippet
        self.body = body
        self.bodyFormat = bodyFormat
        self.folder = folder
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.summary = summary
    }
}
