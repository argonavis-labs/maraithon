import Foundation

/// Files-specific HTTP client. Posts to `POST /api/v1/companion/files`
/// using the same auth + transport shape as `MaraithonClient`, but
/// kept as a separate type so the iMessage-owned client doesn't grow
/// new surface area while the Files server contract is still
/// settling.
///
/// Design choice (same as `NotesIngest` and `VoiceMemosIngest`):
/// rather than threading the files payload through
/// `SyncEngine.enqueue` / `drain` — which today hard-codes the
/// `IngestBatch.messages` field name — we POST directly. The
/// trade-off: files don't get the durable-queue retry the engine
/// provides for iMessage. `FilesSource` mitigates this by only
/// advancing its cursor after the POST returns success, so the next
/// poll re-tries the same batch on failure.
struct FilesIngest: Sendable {
    /// Closure invoked after a successful push so the source can be
    /// mirrored into Spotlight. See `NotesIngest.SpotlightHook` — same
    /// contract: best-effort, errors are swallowed by the caller.
    typealias SpotlightHook = @Sendable ([FilePayload]) async -> Void

    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
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

    /// POST a files batch. Mirrors `NotesIngest.ingestNotes(batch:)`
    /// so a future merge into a shared client is straightforward.
    func ingestFiles(batch: FilesIngestBatch) async throws -> SyncOutcome {
        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: batch)
                let outcome = try await realtime.push(event: "ingest:files", payload: payload)
                if let spotlight {
                    await spotlight(batch.files)
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
        let bodyData = try Self.encoder.encode(batch)
        let gzipped = try Gzip.compress(bodyData)
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: "/api/v1/companion/files")
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
            if let spotlight {
                await spotlight(batch.files)
            }
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

    /// Shared encoder configured to emit ISO-8601 dates. The server
    /// expects strict ISO-8601 UTC; centralising the choice here
    /// means future formatting tweaks live in one place.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Mirrors the HTTP encoder so the realtime channel ships the exact
    /// same wire shape.
    private static func realtimePayload(from batch: FilesIngestBatch) throws -> [String: Any] {
        let data = try encoder.encode(batch)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

/// Wire body for `POST /api/v1/companion/files`.
struct FilesIngestBatch: Codable, Sendable, Equatable {
    let deviceId: UUID
    let source: String
    let files: [FilePayload]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case files
    }
}

/// One file as posted to the server. `textContentBase64` carries
/// the extracted text body (base64 to dodge JSON-escaping costs on
/// pathological payloads); the server caps it at 200 KB on its end
/// regardless of what we send.
struct FilePayload: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let path: String
    let filename: String?
    let `extension`: String?
    let mimeType: String?
    let byteSize: Int64
    let textContentBase64: String?
    let textTruncated: Bool
    let createdAt: Date
    let modifiedAt: Date
    /// Optional on-device summary of the extracted text. Generated
    /// client-side by ``OnDeviceSummarizer`` when the extracted body
    /// is long enough to benefit from compaction. Additive on the
    /// wire — older servers ignore it.
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case path
        case filename
        case `extension`
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case textContentBase64 = "text_content_base64"
        case textTruncated = "text_truncated"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case summary
    }

    init(
        guid: String,
        localId: String,
        path: String,
        filename: String?,
        extension: String?,
        mimeType: String?,
        byteSize: Int64,
        textContentBase64: String?,
        textTruncated: Bool,
        createdAt: Date,
        modifiedAt: Date,
        summary: String? = nil
    ) {
        self.guid = guid
        self.localId = localId
        self.path = path
        self.filename = filename
        self.extension = `extension`
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.textContentBase64 = textContentBase64
        self.textTruncated = textTruncated
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.summary = summary
    }
}
