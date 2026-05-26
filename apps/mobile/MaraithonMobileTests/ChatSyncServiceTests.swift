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
                        ]
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
        let localThread = ChatThread(title: "New conversation")
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
    var sendHandler: ((UUID, UUID, String) throws -> MobileAPIClient.ChatMessageResponse)?

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
        .init(
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
        MagicLinkRequest(id: email, email: email, expiresAt: Date(), developmentLink: nil, developmentToken: nil)
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
