import Foundation

/// Contacts-specific HTTP/realtime client. Posts to
/// `POST /api/v1/companion/contacts`.
struct ContactsIngest: Sendable {
    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    let path: String
    let realtime: RealtimeChannel?

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)",
        path: String = "/api/v1/companion/contacts",
        realtime: RealtimeChannel? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
        self.path = path
        self.realtime = realtime
    }

    func push(deviceId: UUID, contacts: [ContactPayload]) async throws -> SyncOutcome {
        guard !contacts.isEmpty else {
            return SyncOutcome(accepted: 0, duplicate: 0)
        }

        let body = ContactsIngestBody(
            deviceId: deviceId,
            source: "contacts",
            contacts: contacts
        )

        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: body)
                let outcome = try await realtime.push(event: "ingest:contacts", payload: payload)
                return SyncOutcome(
                    accepted: outcome.accepted,
                    duplicate: outcome.duplicate,
                    invalid: outcome.invalid
                )
            } catch is RealtimeChannel.RealtimeChannelError {
                // Best-effort realtime. HTTP is the reliable fallback.
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
        request.timeoutInterval = 180
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
            return SyncOutcome(
                accepted: decoded.accepted,
                duplicate: decoded.duplicate,
                invalid: decoded.invalid
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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func realtimePayload(from body: ContactsIngestBody) throws -> [String: Any] {
        let data = try encoder.encode(body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

struct ContactPostalAddressPayload: Codable, Sendable, Equatable {
    let label: String?
    let street: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case label
        case street
        case city
        case state
        case postalCode = "postal_code"
        case country
    }
}

struct ContactPayload: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let displayName: String?
    let firstName: String?
    let middleName: String?
    let lastName: String?
    let nickname: String?
    let organizationName: String?
    let departmentName: String?
    let jobTitle: String?
    let emails: [String]
    let phones: [String]
    let urls: [String]
    let postalAddresses: [ContactPostalAddressPayload]
    let payloadHash: String

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case displayName = "display_name"
        case firstName = "first_name"
        case middleName = "middle_name"
        case lastName = "last_name"
        case nickname
        case organizationName = "organization_name"
        case departmentName = "department_name"
        case jobTitle = "job_title"
        case emails
        case phones
        case urls
        case postalAddresses = "postal_addresses"
        case payloadHash = "payload_hash"
    }
}

private struct ContactsIngestBody: Codable, Sendable {
    let deviceId: UUID
    let source: String
    let contacts: [ContactPayload]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case contacts
    }
}
