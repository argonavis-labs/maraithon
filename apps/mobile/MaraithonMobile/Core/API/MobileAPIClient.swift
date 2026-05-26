import Foundation

enum MobileAPIError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The production server returned an unexpected response."
        case .unauthorized:
            return "The production session is no longer valid."
        case .server(let message):
            return message
        }
    }
}

@MainActor
struct MobileAPIClient {
    struct MagicLinkResponse: Decodable {
        struct MagicLink: Decodable {
            let email: String
            let expiresInSeconds: TimeInterval

            enum CodingKeys: String, CodingKey {
                case email
                case expiresInSeconds = "expires_in_seconds"
            }
        }

        let magicLink: MagicLink

        enum CodingKeys: String, CodingKey {
            case magicLink = "magic_link"
        }
    }

    struct AuthResponse: Decodable {
        let sessionToken: String
        let user: RemoteUser

        enum CodingKeys: String, CodingKey {
            case sessionToken = "session_token"
            case user
        }
    }

    struct MeResponse: Decodable {
        let user: RemoteUser
    }

    struct TodosResponse: Decodable {
        let todos: [RemoteTodo]
    }

    struct TodoResponse: Decodable {
        let todo: RemoteTodo
    }

    struct PeopleResponse: Decodable {
        let people: [RemotePerson]
    }

    struct PersonResponse: Decodable {
        let person: RemotePerson
    }

    struct RemoteUser: Decodable, Equatable {
        let id: String
        let email: String
        let sessionExpiresAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case email
            case sessionExpiresAt = "session_expires_at"
        }
    }

    struct RemoteTodo: Decodable, Equatable {
        let id: String
        let title: String
        let summary: String?
        let nextAction: String?
        let dueAt: Date?
        let notes: String?
        let priority: Int?
        let status: String
        let closedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case summary
            case nextAction = "next_action"
            case dueAt = "due_at"
            case notes
            case priority
            case status
            case closedAt = "closed_at"
        }
    }

    struct RemotePerson: Decodable, Equatable {
        let id: String
        let displayName: String
        let contactDetails: [String: [String]]
        let relationship: String?
        let status: String
        let notes: String?
        let metadata: [String: StringValue]
        let lastInteractionAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case contactDetails = "contact_details"
            case relationship
            case status
            case notes
            case metadata
            case lastInteractionAt = "last_interaction_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            relationship = try container.decodeIfPresent(String.self, forKey: .relationship)
            status = try container.decode(String.self, forKey: .status)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            metadata = try container.decodeIfPresent([String: StringValue].self, forKey: .metadata) ?? [:]
            lastInteractionAt = try container.decodeIfPresent(Date.self, forKey: .lastInteractionAt)

            let flexibleDetails = try container.decodeIfPresent(
                [String: FlexibleStringArray].self,
                forKey: .contactDetails
            ) ?? [:]
            contactDetails = flexibleDetails.mapValues(\.values)
        }
    }

    struct FlexibleStringArray: Decodable, Equatable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let values = try? container.decode([String].self) {
                self.values = values
            } else if let value = try? container.decode(String.self), !value.isEmpty {
                self.values = [value]
            } else {
                self.values = []
            }
        }
    }

    enum StringValue: Decodable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .string("")
            }
        }

        var string: String? {
            switch self {
            case .string(let value): value
            case .int(let value): String(value)
            case .double(let value): String(value)
            case .bool(let value): String(value)
            }
        }

        var decimal: Decimal? {
            switch self {
            case .string(let value): Decimal(string: value)
            case .int(let value): Decimal(value)
            case .double(let value): Decimal(value)
            case .bool: nil
            }
        }
    }

    let baseURL: URL
    var session: URLSession = .shared

    init(baseURL: URL = AppConfiguration.mobileAPIBaseURL) {
        self.baseURL = baseURL
    }

    func requestMagicLink(email: String) async throws -> MagicLinkResponse {
        try await send(
            path: "/auth/magic-link",
            method: "POST",
            body: ["email": email],
            responseType: MagicLinkResponse.self
        )
    }

    func consumeMagicLink(token: String) async throws -> AuthResponse {
        try await send(
            path: "/auth/magic/\(token)",
            method: "POST",
            responseType: AuthResponse.self
        )
    }

    func me(sessionToken: String) async throws -> MeResponse {
        try await send(path: "/me", sessionToken: sessionToken, responseType: MeResponse.self)
    }

    func signOut(sessionToken: String) async throws {
        let _: EmptyResponse = try await send(
            path: "/session",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: EmptyResponse.self
        )
    }

    func listTodos(sessionToken: String) async throws -> [RemoteTodo] {
        let response: TodosResponse = try await send(
            path: "/todos?limit=200&status=all&sort=updated&dir=desc",
            sessionToken: sessionToken,
            responseType: TodosResponse.self
        )
        return response.todos
    }

    func createTodo(sessionToken: String, payload: [String: Any]) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos",
            method: "POST",
            sessionToken: sessionToken,
            body: ["todo": payload],
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func updateTodo(sessionToken: String, id: UUID, payload: [String: Any]) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["todo": payload],
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func listPeople(sessionToken: String) async throws -> [RemotePerson] {
        let response: PeopleResponse = try await send(
            path: "/people?limit=200&status=active",
            sessionToken: sessionToken,
            responseType: PeopleResponse.self
        )
        return response.people
    }

    func createPerson(sessionToken: String, payload: [String: Any]) async throws -> RemotePerson {
        let response: PersonResponse = try await send(
            path: "/people",
            method: "POST",
            sessionToken: sessionToken,
            body: ["person": payload],
            responseType: PersonResponse.self
        )
        return response.person
    }

    func updatePerson(sessionToken: String, id: UUID, payload: [String: Any]) async throws -> RemotePerson {
        let response: PersonResponse = try await send(
            path: "/people/\(id.uuidString.lowercased())",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["person": payload],
            responseType: PersonResponse.self
        )
        return response.person
    }

    func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        sessionToken: String? = nil,
        body: [String: Any]? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? baseURL
            : URL(string: baseURL.absoluteString + "/")!
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = URL(string: relativePath, relativeTo: base)!.absoluteURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MaraithonMobile/1.0", forHTTPHeaderField: "User-Agent")

        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            if Response.self == EmptyResponse.self, data.isEmpty {
                return EmptyResponse() as! Response
            }
            return try decoder.decode(Response.self, from: data)
        case 401:
            throw MobileAPIError.unauthorized
        default:
            let error = (try? decoder.decode(ServerError.self, from: data))?.error
            throw MobileAPIError.server(error ?? "Production request failed with status \(httpResponse.statusCode).")
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date.")
        }
        return decoder
    }

    private struct ServerError: Decodable {
        let error: String
    }

    private struct EmptyResponse: Decodable {
        init() {}
    }

    nonisolated private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
