import Foundation
import SwiftData
import Testing
@testable import MaraithonMobile

@Suite("Chat Sync Service")
@MainActor
struct ChatSyncServiceTests {
    @Test
    func refreshThreadsMergesRemoteMessagesAndActions() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let threadID = UUID()
        let actionID = UUID()
        let messageID = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_800)
        let workSummary = ChatWorkSummary(
            headline: "Checked open work and replied",
            toolCalls: [
                .init(
                    id: "tool-1",
                    tool: "open_work",
                    label: "Open work",
                    status: "completed",
                    summary: "Returned 2 todos"
                )
            ]
        )
        let api = MockChatAPI()
        api.remoteThreads = [
            .init(
                id: threadID,
                title: "Prep Alex",
                updatedAt: sentAt,
                messages: [
                    .init(
                        id: messageID,
                        role: ChatRole.assistant.rawValue,
                        body: "Confirm this todo?",
                        turnKind: "approval_prompt",
                        messageClass: "approval_prompt",
                        sentAt: sentAt,
                        actions: [
                            .init(
                                id: actionID,
                                kind: "prepared_action_decision",
                                label: "Confirm",
                                decision: ChatActionDecision.confirm.rawValue,
                                style: "primary"
                            )
                        ],
                        workSummary: workSummary
                    )
                ]
            )
        ]

        let service = ChatSyncService(api: api)
        try await service.refreshThreads(modelContext: context, sessionStore: signedInSessionStore())

        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        #expect(threads.count == 1)
        #expect(threads.first?.remoteID == threadID)
        #expect(threads.first?.messages.first?.remoteID == messageID)
        #expect(threads.first?.messages.first?.actions.first?.actionID == actionID)
        #expect(threads.first?.messages.first?.workSummary?.toolCalls.first?.tool == "open_work")
    }

    @Test
    func refreshThreadsStoresOnlyPublicStructuredData() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let threadID = UUID()
        let messageID = UUID()
        let api = MockChatAPI()
        let calculation: JSONValue = .object([
            "expression": .string("2+2"),
            "result": .string("4")
        ])

        api.remoteThreads = [
            .init(
                id: threadID,
                title: "Math",
                messages: [
                    .init(
                        id: messageID,
                        role: ChatRole.assistant.rawValue,
                        body: "2+2 = 4.",
                        structuredData: [
                            "calculation": calculation,
                            "direct_intent": .string("simple_calculation"),
                            "tool_history": .array([]),
                            "run_id": .string(UUID().uuidString),
                            "message_class": .string("assistant_reply")
                        ]
                    )
                ]
            )
        ]

        let service = ChatSyncService(api: api)
        try await service.refreshThreads(modelContext: context, sessionStore: signedInSessionStore())

        let message = try #require(context.fetch(FetchDescriptor<ChatThread>()).first?.messages.first)
        let metadata = try #require(message.storedMetadata)

        #expect(metadata.structuredData == ["calculation": calculation])
        #expect(metadata.structuredData["direct_intent"] == nil)
        #expect(metadata.structuredData["tool_history"] == nil)
    }

    @Test
    func refreshThreadsKeepsPendingRunWorkSummary() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let threadID = UUID()
        let runID = UUID()
        let workSummary = ChatWorkSummary(
            headline: "Checking open work",
            status: ChatRunStatus.running.rawValue,
            toolCalls: [
                .init(
                    id: "tool-1",
                    tool: "open_work",
                    label: "Open work",
                    status: "running",
                    summary: "Running"
                )
            ]
        )
        let api = MockChatAPI()
        api.remoteThreads = [
            .init(
                id: threadID,
                title: "Plan today",
                pendingRun: .init(
                    id: runID,
                    threadID: threadID,
                    status: ChatRunStatus.running.rawValue,
                    workSummary: workSummary
                )
            )
        ]

        let service = ChatSyncService(api: api)
        try await service.refreshThreads(modelContext: context, sessionStore: signedInSessionStore())

        let thread = try #require(context.fetch(FetchDescriptor<ChatThread>()).first)
        #expect(thread.pendingRunID == runID)
        #expect(thread.pendingWorkSummary?.headline == "Checking open work")
        #expect(thread.pendingWorkSummary?.toolCalls.first?.status == "running")
    }

    @Test
    func refreshThreadsUsesLatestMessageForConversationPreview() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let threadID = UUID()
        let messageID = UUID()
        let sentAt = Date(timeIntervalSince1970: 2_400)
        let api = MockChatAPI()
        api.remoteThreads = [
            .init(
                id: threadID,
                title: "Plan today",
                updatedAt: sentAt,
                latestMessage: .init(
                    id: messageID,
                    role: ChatRole.assistant.rawValue,
                    body: "Start with the overdue client follow-up.",
                    turnKind: "assistant_reply",
                    sentAt: sentAt,
                    deliveryState: ChatDeliveryState.delivered.rawValue
                ),
                messages: []
            )
        ]

        let service = ChatSyncService(api: api)
        try await service.refreshThreads(modelContext: context, sessionStore: signedInSessionStore())

        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        #expect(threads.first?.messages.count == 1)
        #expect(threads.first?.sortedMessages.last?.body == "Start with the overdue client follow-up.")
    }

    @Test
    func sendDeduplicatesOptimisticUserMessageByClientMessageID() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let localThread = ChatThread(title: ChatThreadNaming.defaultTitle)
        context.insert(localThread)
        try context.save()

        let api = MockChatAPI()
        api.createdThreadID = UUID()
        api.sendHandler = { threadID, clientMessageID, body in
            let userMessage = MobileAPIClient.RemoteChatMessage(
                id: UUID(),
                clientMessageID: clientMessageID,
                role: ChatRole.user.rawValue,
                body: body,
                turnKind: "user_message",
                sentAt: Date(timeIntervalSince1970: 2_000),
                deliveryState: ChatDeliveryState.sent.rawValue
            )
            let assistantMessage = MobileAPIClient.RemoteChatMessage(
                id: UUID(),
                role: ChatRole.assistant.rawValue,
                body: "Production reply",
                turnKind: "assistant_reply",
                messageClass: "assistant_reply",
                sentAt: Date(timeIntervalSince1970: 2_001),
                deliveryState: ChatDeliveryState.delivered.rawValue,
                runID: UUID()
            )
            return .init(
                thread: .init(
                    id: threadID,
                    title: "Hey",
                    updatedAt: Date(timeIntervalSince1970: 2_001),
                    messages: [userMessage, assistantMessage]
                ),
                run: .init(
                    id: UUID(),
                    threadID: threadID,
                    status: ChatRunStatus.completed.rawValue,
                    startedAt: nil,
                    finishedAt: Date(timeIntervalSince1970: 2_001),
                    error: nil,
                    messageClass: "assistant_reply"
                )
            )
        }

        let service = ChatSyncService(api: api)
        try await service.send(
            "Hey",
            in: localThread,
            modelContext: context,
            sessionStore: signedInSessionStore()
        )

        #expect(localThread.remoteID == api.createdThreadID)
        #expect(localThread.messages.filter { $0.role == .user }.count == 1)
        #expect(localThread.messages.filter { $0.role == .assistant }.count == 1)
        #expect(localThread.messages.first { $0.role == .user }?.deliveryState == .sent)
    }

    @Test
    func renameThreadPersistsRemoteTitleAndSurvivesRefresh() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let remoteID = UUID()
        let localThread = ChatThread(title: "Old title", remoteID: remoteID, syncStatus: .synced)
        context.insert(localThread)
        try context.save()

        let api = MockChatAPI()
        api.remoteThreads = [
            .init(id: remoteID, title: "Old title")
        ]

        let service = ChatSyncService(api: api)
        try await service.renameThread(
            localThread,
            title: "  CEO   briefing follow-up  ",
            modelContext: context,
            sessionStore: signedInSessionStore()
        )

        #expect(api.updatedThreadID == remoteID)
        #expect(api.updatedThreadTitle == "CEO briefing follow-up")
        #expect(localThread.title == "CEO briefing follow-up")

        try await service.refreshThread(
            localThread,
            modelContext: context,
            sessionStore: signedInSessionStore()
        )

        #expect(localThread.title == "CEO briefing follow-up")
    }

    @Test
    func deleteRemoteMessagePersistsAcrossRefresh() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let remoteThreadID = UUID()
        let deletedMessageID = UUID()
        let keptMessageID = UUID()
        let localThread = ChatThread(title: "Board prep", remoteID: remoteThreadID, syncStatus: .synced)
        let keptMessage = ChatMessage(
            body: "Keep this",
            sentAt: Date(timeIntervalSince1970: 2_000),
            role: .user,
            remoteID: keptMessageID,
            deliveryState: .sent,
            thread: localThread
        )
        let deletedMessage = ChatMessage(
            body: "Remove this",
            sentAt: Date(timeIntervalSince1970: 2_001),
            role: .assistant,
            remoteID: deletedMessageID,
            deliveryState: .delivered,
            thread: localThread
        )
        localThread.messages = [keptMessage, deletedMessage]
        context.insert(localThread)
        context.insert(keptMessage)
        context.insert(deletedMessage)
        try context.save()

        let api = MockChatAPI()
        api.remoteThreads = [
            .init(
                id: remoteThreadID,
                title: "Board prep",
                messages: [
                    .init(id: keptMessageID, role: ChatRole.user.rawValue, body: "Keep this"),
                    .init(id: deletedMessageID, role: ChatRole.assistant.rawValue, body: "Remove this")
                ]
            )
        ]

        let service = ChatSyncService(api: api)
        try await service.deleteMessage(
            deletedMessage,
            from: localThread,
            modelContext: context,
            sessionStore: signedInSessionStore()
        )

        #expect(api.deletedThreadID == remoteThreadID)
        #expect(api.deletedMessageID == deletedMessageID)
        #expect(localThread.messages.map(\.body) == ["Keep this"])

        try await service.refreshThread(
            localThread,
            modelContext: context,
            sessionStore: signedInSessionStore()
        )

        #expect(localThread.messages.map(\.body) == ["Keep this"])
    }

    @Test
    func pollPendingRunSurfacesFailedRunWhenNoAssistantMessageArrives() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let remoteThreadID = UUID()
        let runID = UUID()
        let localThread = ChatThread(
            title: "Board prep",
            remoteID: remoteThreadID,
            syncStatus: .synced,
            pendingRunID: runID
        )
        context.insert(localThread)
        try context.save()

        let api = MockChatAPI()
        api.remoteThreads = [
            .init(id: remoteThreadID, title: "Board prep", messages: [])
        ]
        api.runHandler = { id in
            MobileAPIClient.RemoteChatRun(
                id: id,
                threadID: remoteThreadID,
                status: ChatRunStatus.failed.rawValue,
                finishedAt: Date(),
                error: "DBConnection stacktrace token=secret"
            )
        }

        let service = ChatSyncService(api: api)

        do {
            try await service.pollPendingRun(
                in: localThread,
                modelContext: context,
                sessionStore: signedInSessionStore()
            )
            Issue.record("Expected failed assistant run to surface an error")
        } catch {
            let copy = MobileErrorCopy.message(for: error)
            #expect(copy == "Maraithon saved the request and avoided sending an unverified answer.")
            #expect(!copy.contains("Ask for"))
            #expect(!copy.contains("DBConnection"))
            #expect(!copy.contains("token=secret"))
        }

        #expect(localThread.pendingRunID == nil)
    }

    @Test
    func pollPendingRunDoesNotDuplicateFailedRunAssistantMessage() async throws {
        let container = try PersistenceController.makeModelContainer(inMemory: true)
        let context = container.mainContext
        let remoteThreadID = UUID()
        let runID = UUID()
        let assistantMessageID = UUID()
        let localThread = ChatThread(
            title: "Board prep",
            remoteID: remoteThreadID,
            syncStatus: .synced,
            pendingRunID: runID
        )
        context.insert(localThread)
        try context.save()

        let api = MockChatAPI()
        api.remoteThreads = [
            .init(
                id: remoteThreadID,
                title: "Board prep",
                messages: [
                    .init(
                        id: assistantMessageID,
                        role: ChatRole.assistant.rawValue,
                        body: "Maraithon saved the request and avoided sending an unverified answer.",
                        runID: runID
                    )
                ]
            )
        ]
        api.runHandler = { id in
            MobileAPIClient.RemoteChatRun(
                id: id,
                threadID: remoteThreadID,
                status: ChatRunStatus.failed.rawValue,
                finishedAt: Date(),
                error: "Maraithon saved the request and avoided sending an unverified answer."
            )
        }

        let service = ChatSyncService(api: api)
        try await service.pollPendingRun(
            in: localThread,
            modelContext: context,
            sessionStore: signedInSessionStore()
        )

        #expect(localThread.pendingRunID == nil)
        #expect(localThread.messages.filter { $0.role == .assistant }.count == 1)
    }

    private func signedInSessionStore() -> SessionStore {
        let store = SessionStore(authProvider: TestAuthProvider())
        store.user = AuthenticatedUser(
            id: "test@example.com",
            email: "test@example.com",
            signedInAt: Date(),
            sessionExpiresAt: Date().addingTimeInterval(3_600),
            sessionToken: "test-session"
        )
        store.phase = .signedIn
        return store
    }
}

@MainActor
private final class MockChatAPI: MobileChatAPI {
    var remoteThreads: [MobileAPIClient.RemoteChatThread] = []
    var createdThreadID = UUID()
    var updatedThreadID: UUID?
    var updatedThreadTitle: String?
    var deletedThreadID: UUID?
    var deletedMessageID: UUID?
    var sendHandler: ((UUID, UUID, String) throws -> MobileAPIClient.ChatMessageResponse)?
    var runHandler: ((UUID) throws -> MobileAPIClient.RemoteChatRun)?

    func listChatThreads(sessionToken: String) async throws -> [MobileAPIClient.RemoteChatThread] {
        remoteThreads
    }

    func createChatThread(
        sessionToken: String,
        title: String,
        clientThreadID: UUID
    ) async throws -> MobileAPIClient.RemoteChatThread {
        .init(id: createdThreadID, title: title, updatedAt: Date())
    }

    func getChatThread(sessionToken: String, id: UUID) async throws -> MobileAPIClient.RemoteChatThread {
        remoteThreads.first { $0.id == id } ?? .init(id: id, title: "Remote thread")
    }

    func updateChatThread(
        sessionToken: String,
        id: UUID,
        title: String
    ) async throws -> MobileAPIClient.RemoteChatThread {
        updatedThreadID = id
        updatedThreadTitle = title
        let remoteThread = MobileAPIClient.RemoteChatThread(id: id, title: title, updatedAt: Date())
        remoteThreads.removeAll { $0.id == id }
        remoteThreads.append(remoteThread)
        return remoteThread
    }

    func deleteChatMessage(
        sessionToken: String,
        threadID: UUID,
        messageID: UUID
    ) async throws -> MobileAPIClient.RemoteChatThread {
        deletedThreadID = threadID
        deletedMessageID = messageID
        let existing = remoteThreads.first { $0.id == threadID } ?? .init(id: threadID, title: "Remote thread")
        let remoteThread = MobileAPIClient.RemoteChatThread(
            id: existing.id,
            title: existing.title,
            status: existing.status,
            lastTurnAt: existing.lastTurnAt,
            updatedAt: Date(),
            messageCount: existing.messageCount.map { max($0 - 1, 0) },
            latestMessage: nil,
            pendingRun: existing.pendingRun,
            messages: existing.messages.filter { $0.id != messageID }
        )
        remoteThreads.removeAll { $0.id == threadID }
        remoteThreads.append(remoteThread)
        return remoteThread
    }

    func sendChatMessage(
        sessionToken: String,
        threadID: UUID,
        clientMessageID: UUID,
        body: String
    ) async throws -> MobileAPIClient.ChatMessageResponse {
        if let sendHandler {
            return try sendHandler(threadID, clientMessageID, body)
        }
        return .init(thread: .init(id: threadID, title: body), run: nil)
    }

    func getChatRun(sessionToken: String, id: UUID) async throws -> MobileAPIClient.RemoteChatRun {
        if let runHandler {
            return try runHandler(id)
        }

        return MobileAPIClient.RemoteChatRun(
            id: id,
            threadID: createdThreadID,
            status: ChatRunStatus.completed.rawValue,
            startedAt: nil,
            finishedAt: Date(),
            error: nil,
            messageClass: nil
        )
    }

    func decidePreparedAction(
        sessionToken: String,
        id: UUID,
        decision: ChatActionDecision,
        clientMessageID: UUID
    ) async throws -> MobileAPIClient.ChatActionResultResponse {
        .init(preparedAction: nil, thread: remoteThreads.first ?? .init(id: createdThreadID, title: "Remote thread"))
    }
}

@MainActor
private final class TestAuthProvider: AuthProviding {
    func requestMagicLink(email: String) async throws -> MagicLinkRequest {
        MagicLinkRequest(
            id: email,
            email: email,
            expiresAt: Date(),
            developmentLink: nil,
            developmentToken: nil,
            developmentCode: nil
        )
    }

    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser {
        AuthenticatedUser(
            id: "test@example.com",
            email: "test@example.com",
            signedInAt: Date(),
            sessionExpiresAt: Date().addingTimeInterval(3_600),
            sessionToken: "test-session"
        )
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        nil
    }

    func signOut() async throws {}
}
