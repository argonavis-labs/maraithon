import Foundation

/// HTTP client surface for `/api/v1/companion/device-keys`. Sibling of
/// `MaraithonClient` — kept separate so the crypto subsystem doesn't
/// pull the rest of the ingest API surface into its dependency graph.
///
/// The client uploads a public key on first encryption-mode enable
/// (and after rotation) and reads the server's view of the current
/// key on demand (e.g. when the user opens the Privacy tab so we can
/// surface "your device key id is k-abcd, last seen at ...").
struct DeviceKeyClient: Sendable {
    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)"
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
    }

    /// Uploads `key` to `POST /api/v1/companion/device-keys`. Returns
    /// the server's echo of the persisted row. Idempotent for the same
    /// `key_id`.
    func upload(_ key: DeviceKey) async throws -> DeviceKeyResponse {
        let body = DeviceKeyUploadBody(
            keyId: key.keyId,
            publicKey: key.publicKeyBase64
        )
        let payload = try JSONEncoder().encode(body)
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/device-keys",
            body: payload,
            contentType: "application/json"
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(DeviceKeyResponse.self, from: data)
    }

    /// Fetches the server's record of the current key for this
    /// device. Returns `nil` when no key has been published yet (the
    /// server returns `{"key": null}` in that case). Used by Settings
    /// to spot mismatches the user should be aware of.
    func fetchCurrent() async throws -> DeviceKeyResponse? {
        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/device-keys/me",
            body: nil,
            contentType: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(DeviceKeyMeEnvelope.self, from: data)
        return envelope.key
    }

    // MARK: - Request shaping

    private func makeRequest(
        method: String,
        path: String,
        body: Data?,
        contentType: String?
    ) async throws -> URLRequest {
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MaraithonClientError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return
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
}

/// `POST /api/v1/companion/device-keys` body shape.
private struct DeviceKeyUploadBody: Codable, Sendable {
    let keyId: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
    }
}

/// Server echo for a stored device key. Matches the `{"key_id":
/// "...", "public_key": "..."}` shape returned by both
/// `POST /api/v1/companion/device-keys` and the `key` field on
/// `GET /api/v1/companion/device-keys/me`.
struct DeviceKeyResponse: Codable, Sendable, Equatable {
    let keyId: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
    }
}

/// `{"key": null}` or `{"key": {...}}` envelope from GET /me.
private struct DeviceKeyMeEnvelope: Codable, Sendable {
    let key: DeviceKeyResponse?
}
