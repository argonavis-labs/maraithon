import Foundation

enum MobileAPIError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case unauthorized
    case server(String)
    case serverResponse(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Maraithon returned an unexpected response."
        case .unauthorized:
            return "Sign-in expired. Sign in again."
        case .server(let message):
            return message
        case .serverResponse(_, let message):
            return message
        }
    }

    var isNotFound: Bool {
        switch self {
        case .server("not_found"):
            return true
        case .serverResponse(let code, _):
            return code == "not_found"
        default:
            return false
        }
    }
}

struct MobileAPIClient: Sendable {
    typealias RequestBody = [String: JSONValue]

    struct MagicLinkResponse: Decodable, Sendable {
        struct MagicLink: Decodable, Sendable {
            let email: String
            let expiresInSeconds: TimeInterval
            let delivery: String?

            enum CodingKeys: String, CodingKey {
                case email
                case expiresInSeconds = "expires_in_seconds"
                case delivery
            }
        }

        let magicLink: MagicLink

        enum CodingKeys: String, CodingKey {
            case magicCode = "magic_code"
            case magicLink = "magic_link"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let magicCode = try container.decodeIfPresent(MagicLink.self, forKey: .magicCode) {
                magicLink = magicCode
            } else {
                magicLink = try container.decode(MagicLink.self, forKey: .magicLink)
            }
        }
    }

    struct AuthResponse: Decodable, Sendable {
        let sessionToken: String
        let user: RemoteUser

        enum CodingKeys: String, CodingKey {
            case sessionToken = "session_token"
            case user
        }
    }

    struct MeResponse: Decodable, Sendable {
        let user: RemoteUser
    }

    struct TodosResponse: Decodable, Sendable {
        let todos: [RemoteTodo]
    }

    struct TodoActivityResponse: Decodable, Sendable {
        let activity: [RemoteTodoActivity]
    }

    struct TodoResponse: Decodable, Sendable {
        let todo: RemoteTodo
    }

    struct PeopleResponse: Decodable, Sendable {
        let people: [RemotePerson]
    }

    struct PersonResponse: Decodable, Sendable {
        let person: RemotePerson
    }

    struct ReconnectResponse: Decodable, Sendable {
        let suggestions: [RemoteReconnectSuggestion]
    }

    struct RemoteReconnectSuggestion: Decodable, Equatable, Sendable, Identifiable {
        let person: RemotePerson
        let category: String
        let headline: String
        let reason: String
        let suggestedAction: String?
        let daysSinceLast: Int?
        let cadenceDays: Int?
        let communicationScore: Int?
        let overdue: Bool
        let openWork: [RemoteOpenWork]

        var id: String { person.id }

        enum CodingKeys: String, CodingKey {
            case person
            case category
            case headline
            case reason
            case suggestedAction = "suggested_action"
            case daysSinceLast = "days_since_last"
            case cadenceDays = "cadence_days"
            case communicationScore = "communication_score"
            case overdue
            case openWork = "open_work"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            person = try container.decode(RemotePerson.self, forKey: .person)
            category = try container.decode(String.self, forKey: .category)
            headline = try container.decode(String.self, forKey: .headline)
            reason = try container.decode(String.self, forKey: .reason)
            suggestedAction = try container.decodeIfPresent(String.self, forKey: .suggestedAction)
            daysSinceLast = try container.decodeIfPresent(Int.self, forKey: .daysSinceLast)
            cadenceDays = try container.decodeIfPresent(Int.self, forKey: .cadenceDays)
            communicationScore = try container.decodeIfPresent(Int.self, forKey: .communicationScore)
            overdue = try container.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
            openWork = try container.decodeIfPresent([RemoteOpenWork].self, forKey: .openWork) ?? []
        }
    }

    struct RemoteOpenWork: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    struct RemoteUser: Decodable, Equatable, Sendable {
        let id: String
        let email: String
        let sessionExpiresAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case email
            case sessionExpiresAt = "session_expires_at"
        }
    }

    struct RemoteTodo: Decodable, Equatable, Sendable {
        let id: String
        let source: String?
        let title: String
        let summary: String?
        let nextAction: String?
        let dueAt: Date?
        let notes: String?
        let priority: Int?
        let status: String
        let closedAt: Date?
        let actionCard: RemoteActionCard?
        let relatedPeople: [RemoteRelatedPerson]

        enum CodingKeys: String, CodingKey {
            case id
            case source
            case title
            case summary
            case nextAction = "next_action"
            case dueAt = "due_at"
            case notes
            case priority
            case status
            case closedAt = "closed_at"
            case actionCard = "action_card"
            case relatedPeople = "related_people"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            title = try container.decode(String.self, forKey: .title)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            priority = try container.decodeIfPresent(Int.self, forKey: .priority)
            status = try container.decode(String.self, forKey: .status)
            closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
            actionCard = try container.decodeIfPresent(RemoteActionCard.self, forKey: .actionCard)
            relatedPeople = try container.decodeIfPresent([RemoteRelatedPerson].self, forKey: .relatedPeople) ?? []
        }

        init(
            id: String,
            source: String? = nil,
            title: String,
            summary: String?,
            nextAction: String?,
            dueAt: Date?,
            notes: String?,
            priority: Int?,
            status: String,
            closedAt: Date?,
            actionCard: RemoteActionCard? = nil,
            relatedPeople: [RemoteRelatedPerson] = []
        ) {
            self.id = id
            self.source = source
            self.title = title
            self.summary = summary
            self.nextAction = nextAction
            self.dueAt = dueAt
            self.notes = notes
            self.priority = priority
            self.status = status
            self.closedAt = closedAt
            self.actionCard = actionCard
            self.relatedPeople = relatedPeople
        }
    }

    struct RemoteBrief: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let cadence: String
        let title: String
        let summary: String?
        let body: String?
        let status: String
        let scheduledFor: Date?
        let sentAt: Date?
        let linkedTodoIDs: [String]
        let insertedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case cadence
            case title
            case summary
            case body
            case status
            case scheduledFor = "scheduled_for"
            case sentAt = "sent_at"
            case linkedTodoIDs = "linked_todo_ids"
            case insertedAt = "inserted_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            cadence = try container.decode(String.self, forKey: .cadence)
            title = try container.decode(String.self, forKey: .title)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending"
            scheduledFor = try container.decodeIfPresent(Date.self, forKey: .scheduledFor)
            sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
            linkedTodoIDs = try container.decodeIfPresent([String].self, forKey: .linkedTodoIDs) ?? []
            insertedAt = try container.decodeIfPresent(Date.self, forKey: .insertedAt)
        }

        var referenceDate: Date? {
            scheduledFor ?? insertedAt
        }
    }

    private struct BriefsResponse: Decodable, Sendable {
        let briefs: [RemoteBrief]
    }

    func listBriefs(sessionToken: String, limit: Int = 8) async throws -> [RemoteBrief] {
        let clampedLimit = max(1, min(limit, 30))
        let response: BriefsResponse = try await send(
            path: "/briefs?limit=\(clampedLimit)",
            sessionToken: sessionToken,
            responseType: BriefsResponse.self
        )
        return response.briefs
    }

    struct RemoteRelatedPerson: Decodable, Equatable, Sendable {
        let id: String
        let displayName: String?
        let relationship: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case relationship
        }
    }

    struct RemoteTodoActivity: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let eventType: String
        let actorType: String
        let actorID: String?
        let actorLabel: String?
        let todoID: String?
        let todoTitle: String?
        let todoSource: String?
        let metadata: [String: StringValue]
        let occurredAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case eventType = "event_type"
            case actorType = "actor_type"
            case actorID = "actor_id"
            case actorLabel = "actor_label"
            case todoID = "todo_id"
            case todoTitle = "todo_title"
            case todoSource = "todo_source"
            case metadata
            case occurredAt = "occurred_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            eventType = try container.decode(String.self, forKey: .eventType)
            actorType = try container.decode(String.self, forKey: .actorType)
            actorID = try container.decodeIfPresent(String.self, forKey: .actorID)
            actorLabel = try container.decodeIfPresent(String.self, forKey: .actorLabel)
            todoID = try container.decodeIfPresent(String.self, forKey: .todoID)
            todoTitle = try container.decodeIfPresent(String.self, forKey: .todoTitle)
            todoSource = try container.decodeIfPresent(String.self, forKey: .todoSource)
            metadata = try container.decodeIfPresent([String: StringValue].self, forKey: .metadata) ?? [:]
            occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        }

        init(
            id: String,
            eventType: String,
            actorType: String,
            actorID: String? = nil,
            actorLabel: String? = nil,
            todoID: String? = nil,
            todoTitle: String? = nil,
            todoSource: String? = nil,
            metadata: [String: StringValue] = [:],
            occurredAt: Date
        ) {
            self.id = id
            self.eventType = eventType
            self.actorType = actorType
            self.actorID = actorID
            self.actorLabel = actorLabel
            self.todoID = todoID
            self.todoTitle = todoTitle
            self.todoSource = todoSource
            self.metadata = metadata
            self.occurredAt = occurredAt
        }
    }

    struct RemoteActionCard: Decodable, Equatable, Sendable {
        struct ContextItem: Decodable, Equatable, Sendable {
            let label: String?
            let value: String?
        }

        struct SourceAction: Decodable, Equatable, Sendable {
            let provider: String?
            let providerLabel: String?
            let openURL: String?
            let openLabel: String?
            let draftText: String?
            let draftKind: String?
            let recipient: String?
            let recipientHandle: String?
            let subject: String?
            let participants: [CardParticipant]
            let conversation: [CardConversationMessage]

            enum CodingKeys: String, CodingKey {
                case provider
                case providerLabel = "provider_label"
                case openURL = "open_url"
                case openLabel = "open_label"
                case draftText = "draft_text"
                case draftKind = "draft_kind"
                case recipient
                case recipientHandle = "recipient_handle"
                case subject
                case participants
                case conversation
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                provider = try container.decodeIfPresent(String.self, forKey: .provider)
                providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel)
                openURL = try container.decodeIfPresent(String.self, forKey: .openURL)
                openLabel = try container.decodeIfPresent(String.self, forKey: .openLabel)
                draftText = try container.decodeIfPresent(String.self, forKey: .draftText)
                draftKind = try container.decodeIfPresent(String.self, forKey: .draftKind)
                recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
                recipientHandle = try container.decodeIfPresent(String.self, forKey: .recipientHandle)
                subject = try container.decodeIfPresent(String.self, forKey: .subject)
                participants = try container.decodeIfPresent([CardParticipant].self, forKey: .participants) ?? []
                conversation = try container.decodeIfPresent([CardConversationMessage].self, forKey: .conversation) ?? []
            }
        }

        let decisionPrompt: String?
        let contextItems: [ContextItem]
        let whyNow: String?
        let sourceContext: String?
        let nextBestAction: String?
        let draftPreview: String?
        let evidenceExcerpt: String?
        let sourceAction: SourceAction?

        enum CodingKeys: String, CodingKey {
            case decisionPrompt = "decision_prompt"
            case contextItems = "context_items"
            case whyNow = "why_now"
            case sourceContext = "source_context"
            case nextBestAction = "next_best_action"
            case draftPreview = "draft_preview"
            case evidenceExcerpt = "evidence_excerpt"
            case sourceAction = "source_action"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            decisionPrompt = try container.decodeIfPresent(String.self, forKey: .decisionPrompt)
            contextItems = try container.decodeIfPresent([ContextItem].self, forKey: .contextItems) ?? []
            whyNow = try container.decodeIfPresent(String.self, forKey: .whyNow)
            sourceContext = try container.decodeIfPresent(String.self, forKey: .sourceContext)
            nextBestAction = try container.decodeIfPresent(String.self, forKey: .nextBestAction)
            draftPreview = try container.decodeIfPresent(String.self, forKey: .draftPreview)
            evidenceExcerpt = try container.decodeIfPresent(String.self, forKey: .evidenceExcerpt)
            sourceAction = try container.decodeIfPresent(SourceAction.self, forKey: .sourceAction)
        }

        init(
            decisionPrompt: String? = nil,
            contextItems: [ContextItem] = [],
            whyNow: String? = nil,
            sourceContext: String? = nil,
            nextBestAction: String? = nil,
            draftPreview: String? = nil,
            evidenceExcerpt: String? = nil,
            sourceAction: SourceAction? = nil
        ) {
            self.decisionPrompt = decisionPrompt
            self.contextItems = contextItems
            self.whyNow = whyNow
            self.sourceContext = sourceContext
            self.nextBestAction = nextBestAction
            self.draftPreview = draftPreview
            self.evidenceExcerpt = evidenceExcerpt
            self.sourceAction = sourceAction
        }
    }

    struct RemotePerson: Decodable, Equatable, Sendable {
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

    struct FlexibleStringArray: Decodable, Equatable, Sendable {
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

    enum StringValue: Decodable, Equatable, Sendable {
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
    let session: URLSession

    /// Shared session with bounded timeouts so a slow or hung request never leaves the
    /// UI spinning indefinitely (the default `.shared` request timeout is 60s).
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL = AppConfiguration.mobileAPIBaseURL, session: URLSession = MobileAPIClient.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func requestMagicLink(email: String) async throws -> MagicLinkResponse {
        try await send(
            path: "/auth/magic-link",
            method: "POST",
            body: ["email": .string(email)],
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

    func consumeMagicCode(code: String) async throws -> AuthResponse {
        try await send(
            path: "/auth/magic-code",
            method: "POST",
            body: ["code": .string(code)],
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

    struct IdentityResponse: Decodable, Sendable {
        struct Identity: Decodable, Sendable, Identifiable {
            let confirmed: Bool
            let displayName: String?
            let emails: [String]
            let phones: [String]

            var id: String {
                ([displayName ?? ""] + emails + phones).joined(separator: "|")
            }

            enum CodingKeys: String, CodingKey {
                case confirmed
                case displayName = "display_name"
                case emails
                case phones
            }
        }

        let identity: Identity
    }

    func getIdentity(sessionToken: String) async throws -> IdentityResponse.Identity {
        let response: IdentityResponse = try await send(
            path: "/identity",
            sessionToken: sessionToken,
            responseType: IdentityResponse.self
        )
        return response.identity
    }

    func confirmIdentity(
        sessionToken: String,
        displayName: String?,
        emails: [String],
        phones: [String]
    ) async throws -> IdentityResponse.Identity {
        let response: IdentityResponse = try await send(
            path: "/identity",
            method: "PUT",
            sessionToken: sessionToken,
            body: [
                "display_name": .string(displayName ?? ""),
                "emails": .array(emails.map { .string($0) }),
                "phones": .array(phones.map { .string($0) })
            ],
            responseType: IdentityResponse.self
        )
        return response.identity
    }

    func listTodos(sessionToken: String, includeCards: Bool = true) async throws -> [RemoteTodo] {
        let response: TodosResponse = try await send(
            path: "/todos?limit=500&status=all&sort=updated&dir=desc&include_cards=\(includeCards)",
            sessionToken: sessionToken,
            responseType: TodosResponse.self
        )
        return response.todos
    }

    func listTodoActivity(sessionToken: String, limit: Int = 100) async throws -> [RemoteTodoActivity] {
        let clampedLimit = max(1, min(limit, 200))
        let response: TodoActivityResponse = try await send(
            path: "/todo-activity?limit=\(clampedLimit)",
            sessionToken: sessionToken,
            responseType: TodoActivityResponse.self
        )
        return response.activity
    }

    func createTodo(sessionToken: String, payload: RequestBody) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos?include_cards=true",
            method: "POST",
            sessionToken: sessionToken,
            body: ["todo": .object(payload)],
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func updateTodo(sessionToken: String, id: UUID, payload: RequestBody) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())?include_cards=true",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["todo": .object(payload)],
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func deleteTodo(sessionToken: String, id: UUID) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func listPeople(sessionToken: String) async throws -> [RemotePerson] {
        let pageSize = 500
        var offset = 0
        var people: [RemotePerson] = []

        while true {
            let response: PeopleResponse = try await send(
                path: "/people?limit=\(pageSize)&offset=\(offset)&status=all",
                sessionToken: sessionToken,
                responseType: PeopleResponse.self
            )

            people.append(contentsOf: response.people)

            if response.people.count < pageSize {
                return people
            }

            offset += pageSize
        }
    }

    func reconnectSuggestions(
        sessionToken: String,
        limit: Int = 12
    ) async throws -> [RemoteReconnectSuggestion] {
        let response: ReconnectResponse = try await send(
            path: "/people/reconnect?limit=\(limit)",
            sessionToken: sessionToken,
            responseType: ReconnectResponse.self
        )
        return response.suggestions
    }

    func createPerson(sessionToken: String, payload: RequestBody) async throws -> RemotePerson {
        let response: PersonResponse = try await send(
            path: "/people",
            method: "POST",
            sessionToken: sessionToken,
            body: ["person": .object(payload)],
            responseType: PersonResponse.self
        )
        return response.person
    }

    func updatePerson(sessionToken: String, id: UUID, payload: RequestBody) async throws -> RemotePerson {
        let response: PersonResponse = try await send(
            path: "/people/\(id.uuidString.lowercased())",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["person": .object(payload)],
            responseType: PersonResponse.self
        )
        return response.person
    }

    func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        sessionToken: String? = nil,
        body: RequestBody? = nil,
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
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
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
            if let error = try? decoder.decode(ServerError.self, from: data) {
                if let message = error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty
                {
                    throw MobileAPIError.serverResponse(
                        code: error.error ?? "request_failed",
                        message: message
                    )
                }

                if let code = error.error {
                    throw MobileAPIError.server(code)
                }
            }

            throw MobileAPIError.server("request_failed")
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

    private struct ServerError: Decodable, Sendable {
        let error: String?
        let message: String?
    }

    private struct EmptyResponse: Decodable, Sendable {
        init() {}
    }

    private static let iso8601WithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    nonisolated private static func date(from value: String) -> Date? {
        if let date = try? iso8601WithFractionalSeconds.parse(value) {
            return date
        }

        return try? iso8601.parse(value)
    }
}
