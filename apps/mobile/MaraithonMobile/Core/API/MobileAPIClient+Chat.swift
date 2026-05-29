import Foundation

@MainActor
protocol MobileChatAPI {
    func listChatThreads(sessionToken: String) async throws -> [MobileAPIClient.RemoteChatThread]
    func createChatThread(
        sessionToken: String,
        title: String,
        clientThreadID: UUID
    ) async throws -> MobileAPIClient.RemoteChatThread
    func getChatThread(sessionToken: String, id: UUID) async throws -> MobileAPIClient.RemoteChatThread
    func updateChatThread(
        sessionToken: String,
        id: UUID,
        title: String
    ) async throws -> MobileAPIClient.RemoteChatThread
    func deleteChatMessage(
        sessionToken: String,
        threadID: UUID,
        messageID: UUID
    ) async throws -> MobileAPIClient.RemoteChatThread
    func sendChatMessage(
        sessionToken: String,
        threadID: UUID,
        clientMessageID: UUID,
        body: String
    ) async throws -> MobileAPIClient.ChatMessageResponse
    func getChatRun(sessionToken: String, id: UUID) async throws -> MobileAPIClient.RemoteChatRun
    func decidePreparedAction(
        sessionToken: String,
        id: UUID,
        decision: ChatActionDecision,
        clientMessageID: UUID
    ) async throws -> MobileAPIClient.ChatActionResultResponse
}

extension MobileAPIClient: MobileChatAPI {
    struct ChatThreadsResponse: Decodable {
        let threads: [RemoteChatThread]
    }

    struct ChatThreadResponse: Decodable {
        let thread: RemoteChatThread
    }

    struct ChatMessageResponse: Decodable {
        let thread: RemoteChatThread
        let run: RemoteChatRun?
    }

    struct ChatRunResponse: Decodable {
        let run: RemoteChatRun
    }

    struct ChatActionResultResponse: Decodable {
        let preparedAction: RemotePreparedAction?
        let thread: RemoteChatThread

        enum CodingKeys: String, CodingKey {
            case preparedAction = "prepared_action"
            case thread
        }
    }

    struct RemotePreparedAction: Decodable, Equatable, Identifiable {
        let id: UUID
        let status: String
        let actionType: String
        let targetType: String?
        let previewText: String?
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case actionType = "action_type"
            case targetType = "target_type"
            case previewText = "preview_text"
            case expiresAt = "expires_at"
        }
    }

    struct RemoteChatThread: Decodable, Equatable, Identifiable {
        let id: UUID
        let title: String
        let status: String
        let lastTurnAt: Date?
        let updatedAt: Date?
        let messageCount: Int?
        let latestMessage: RemoteChatMessage?
        let pendingRun: RemoteChatRun?
        let messages: [RemoteChatMessage]

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case status
            case lastTurnAt = "last_turn_at"
            case updatedAt = "updated_at"
            case messageCount = "message_count"
            case latestMessage = "latest_message"
            case pendingRun = "pending_run"
            case messages
        }

        init(
            id: UUID,
            title: String,
            status: String = "open",
            lastTurnAt: Date? = nil,
            updatedAt: Date? = nil,
            messageCount: Int? = nil,
            latestMessage: RemoteChatMessage? = nil,
            pendingRun: RemoteChatRun? = nil,
            messages: [RemoteChatMessage] = []
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.lastTurnAt = lastTurnAt
            self.updatedAt = updatedAt
            self.messageCount = messageCount
            self.latestMessage = latestMessage
            self.pendingRun = pendingRun
            self.messages = messages
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "open"
            lastTurnAt = try container.decodeIfPresent(Date.self, forKey: .lastTurnAt)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount)
            latestMessage = try container.decodeIfPresent(RemoteChatMessage.self, forKey: .latestMessage)
            pendingRun = try container.decodeIfPresent(RemoteChatRun.self, forKey: .pendingRun)
            messages = try container.decodeIfPresent([RemoteChatMessage].self, forKey: .messages) ?? []
        }
    }

    struct RemoteChatMessage: Decodable, Equatable, Identifiable {
        let id: UUID
        let clientMessageID: UUID?
        let role: String
        let body: String
        let turnKind: String?
        let messageClass: String?
        let sentAt: Date?
        let deliveryState: String?
        let runID: UUID?
        let actions: [RemoteChatAction]
        let linkedTodo: JSONValue?
        let workSummary: ChatWorkSummary?
        let structuredData: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case id
            case clientMessageID = "client_message_id"
            case role
            case body
            case turnKind = "turn_kind"
            case messageClass = "message_class"
            case sentAt = "sent_at"
            case deliveryState = "delivery_state"
            case runID = "run_id"
            case actions
            case linkedTodo = "linked_todo"
            case workSummary = "work_summary"
            case structuredData = "structured_data"
        }

        init(
            id: UUID,
            clientMessageID: UUID? = nil,
            role: String,
            body: String,
            turnKind: String? = nil,
            messageClass: String? = nil,
            sentAt: Date? = nil,
            deliveryState: String? = nil,
            runID: UUID? = nil,
            actions: [RemoteChatAction] = [],
            linkedTodo: JSONValue? = nil,
            workSummary: ChatWorkSummary? = nil,
            structuredData: [String: JSONValue] = [:]
        ) {
            self.id = id
            self.clientMessageID = clientMessageID
            self.role = role
            self.body = body
            self.turnKind = turnKind
            self.messageClass = messageClass
            self.sentAt = sentAt
            self.deliveryState = deliveryState
            self.runID = runID
            self.actions = actions
            self.linkedTodo = linkedTodo
            self.workSummary = workSummary
            self.structuredData = structuredData
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            clientMessageID = try container.decodeIfPresent(UUID.self, forKey: .clientMessageID)
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? ChatRole.assistant.rawValue
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            turnKind = try container.decodeIfPresent(String.self, forKey: .turnKind)
            messageClass = try container.decodeIfPresent(String.self, forKey: .messageClass)
            sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
            deliveryState = try container.decodeIfPresent(String.self, forKey: .deliveryState)
            runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
            actions = try container.decodeIfPresent([RemoteChatAction].self, forKey: .actions) ?? []
            linkedTodo = try container.decodeIfPresent(JSONValue.self, forKey: .linkedTodo)
            workSummary = try container.decodeIfPresent(ChatWorkSummary.self, forKey: .workSummary)
            structuredData = try container.decodeIfPresent([String: JSONValue].self, forKey: .structuredData) ?? [:]
        }
    }

    struct RemoteChatAction: Decodable, Equatable, Identifiable {
        let id: UUID
        let kind: String
        let label: String
        let decision: String
        let style: String
    }

    struct RemoteChatRun: Decodable, Equatable, Identifiable {
        let id: UUID
        let threadID: UUID
        let status: String
        let startedAt: Date?
        let finishedAt: Date?
        let error: String?
        let messageClass: String?
        let workSummary: ChatWorkSummary?

        var runStatus: ChatRunStatus {
            ChatRunStatus(rawValue: status) ?? .running
        }

        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "thread_id"
            case status
            case startedAt = "started_at"
            case finishedAt = "finished_at"
            case error
            case messageClass = "message_class"
            case workSummary = "work_summary"
        }

        init(
            id: UUID,
            threadID: UUID,
            status: String,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            error: String? = nil,
            messageClass: String? = nil,
            workSummary: ChatWorkSummary? = nil
        ) {
            self.id = id
            self.threadID = threadID
            self.status = status
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.error = error
            self.messageClass = messageClass
            self.workSummary = workSummary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            threadID = try container.decode(UUID.self, forKey: .threadID)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ChatRunStatus.running.rawValue
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            messageClass = try container.decodeIfPresent(String.self, forKey: .messageClass)
            workSummary = try container.decodeIfPresent(ChatWorkSummary.self, forKey: .workSummary)
        }
    }

    func listChatThreads(sessionToken: String) async throws -> [RemoteChatThread] {
        let response: ChatThreadsResponse = try await send(
            path: "/chat/threads?limit=100",
            sessionToken: sessionToken,
            responseType: ChatThreadsResponse.self
        )
        return response.threads
    }

    func createChatThread(
        sessionToken: String,
        title: String,
        clientThreadID: UUID
    ) async throws -> RemoteChatThread {
        let response: ChatThreadResponse = try await send(
            path: "/chat/threads",
            method: "POST",
            sessionToken: sessionToken,
            body: [
                "thread": [
                    "client_thread_id": clientThreadID.uuidString.lowercased(),
                    "title": title
                ]
            ],
            responseType: ChatThreadResponse.self
        )
        return response.thread
    }

    func getChatThread(sessionToken: String, id: UUID) async throws -> RemoteChatThread {
        let response: ChatThreadResponse = try await send(
            path: "/chat/threads/\(id.uuidString.lowercased())",
            sessionToken: sessionToken,
            responseType: ChatThreadResponse.self
        )
        return response.thread
    }

    func updateChatThread(
        sessionToken: String,
        id: UUID,
        title: String
    ) async throws -> RemoteChatThread {
        let response: ChatThreadResponse = try await send(
            path: "/chat/threads/\(id.uuidString.lowercased())",
            method: "PATCH",
            sessionToken: sessionToken,
            body: [
                "thread": [
                    "title": title
                ]
            ],
            responseType: ChatThreadResponse.self
        )
        return response.thread
    }

    func sendChatMessage(
        sessionToken: String,
        threadID: UUID,
        clientMessageID: UUID,
        body: String
    ) async throws -> ChatMessageResponse {
        try await send(
            path: "/chat/threads/\(threadID.uuidString.lowercased())/messages",
            method: "POST",
            sessionToken: sessionToken,
            body: [
                "message": [
                    "client_message_id": clientMessageID.uuidString.lowercased(),
                    "body": body
                ]
            ],
            responseType: ChatMessageResponse.self
        )
    }

    func deleteChatMessage(
        sessionToken: String,
        threadID: UUID,
        messageID: UUID
    ) async throws -> RemoteChatThread {
        let response: ChatThreadResponse = try await send(
            path: "/chat/threads/\(threadID.uuidString.lowercased())/messages/\(messageID.uuidString.lowercased())",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: ChatThreadResponse.self
        )
        return response.thread
    }

    func getChatRun(sessionToken: String, id: UUID) async throws -> RemoteChatRun {
        let response: ChatRunResponse = try await send(
            path: "/chat/runs/\(id.uuidString.lowercased())",
            sessionToken: sessionToken,
            responseType: ChatRunResponse.self
        )
        return response.run
    }

    func decidePreparedAction(
        sessionToken: String,
        id: UUID,
        decision: ChatActionDecision,
        clientMessageID: UUID
    ) async throws -> ChatActionResultResponse {
        try await send(
            path: "/chat/prepared-actions/\(id.uuidString.lowercased())/decision",
            method: "POST",
            sessionToken: sessionToken,
            body: [
                "decision": decision.rawValue,
                "client_message_id": clientMessageID.uuidString.lowercased()
            ],
            responseType: ChatActionResultResponse.self
        )
    }
}
