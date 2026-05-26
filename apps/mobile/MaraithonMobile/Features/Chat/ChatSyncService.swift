import Foundation
import SwiftData

enum ChatSyncError: LocalizedError, Equatable {
    case missingSession
    case emptyMessage
    case pollingTimedOut

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Sign in again to keep chatting with Maraithon."
        case .emptyMessage:
            return "Message is empty."
        case .pollingTimedOut:
            return "Maraithon is still working. Pull to refresh this chat in a moment."
        }
    }
}

@MainActor
struct ChatSyncService {
    private let api: any MobileChatAPI
    private let now: () -> Date
    private let pollIntervalNanoseconds: UInt64
    private let maxPollAttempts: Int

    init(
        api: any MobileChatAPI = MobileAPIClient(),
        now: @escaping () -> Date = Date.init,
        pollIntervalNanoseconds: UInt64 = 1_500_000_000,
        maxPollAttempts: Int = 45
    ) {
        self.api = api
        self.now = now
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPollAttempts = maxPollAttempts
    }

    func refreshThreads(modelContext: ModelContext, sessionStore: SessionStore) async throws {
        let sessionToken = try sessionToken(from: sessionStore)
        let remoteThreads = try await api.listChatThreads(sessionToken: sessionToken)

        for remoteThread in remoteThreads {
            try merge(remoteThread, modelContext: modelContext)
        }

        try modelContext.save()
    }

    func refreshThread(
        _ thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        guard let remoteID = thread.remoteID else { return }
        let sessionToken = try sessionToken(from: sessionStore)
        let remoteThread = try await api.getChatThread(sessionToken: sessionToken, id: remoteID)
        try merge(remoteThread, modelContext: modelContext, preferredThread: thread)
        try modelContext.save()
    }

    @discardableResult
    func send(
        _ text: String,
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws -> UUID? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ChatSyncError.emptyMessage }

        let sessionToken = try sessionToken(from: sessionStore)
        let clientMessageID = UUID()
        let userMessage = optimisticUserMessage(body: body, clientMessageID: clientMessageID, thread: thread)

        modelContext.insert(userMessage)
        thread.messages.append(userMessage)
        thread.updatedAt = now()
        thread.syncStatus = .syncing

        if thread.title == "New conversation" {
            thread.title = ChatThreadNaming.title(for: body)
        }

        try modelContext.save()

        do {
            let remoteThread = try await ensureRemoteThread(
                thread,
                sessionToken: sessionToken,
                modelContext: modelContext
            )

            let response = try await api.sendChatMessage(
                sessionToken: sessionToken,
                threadID: remoteThread.id,
                clientMessageID: clientMessageID,
                body: body
            )

            try merge(response.thread, modelContext: modelContext, preferredThread: thread)
            if let run = response.run {
                apply(run, to: thread)
            }

            try modelContext.save()
            return response.run?.runStatus.isPending == true ? response.run?.id : thread.pendingRunID
        } catch {
            userMessage.deliveryState = .failed
            thread.syncStatus = .failed
            thread.updatedAt = now()
            try? modelContext.save()
            throw error
        }
    }

    func pollPendingRun(
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        guard let runID = thread.pendingRunID else { return }
        let sessionToken = try sessionToken(from: sessionStore)

        for _ in 0..<maxPollAttempts {
            try Task.checkCancellation()

            let run = try await api.getChatRun(sessionToken: sessionToken, id: runID)
            apply(run, to: thread)
            try modelContext.save()

            if !run.runStatus.isPending {
                try await refreshThread(thread, modelContext: modelContext, sessionStore: sessionStore)
                return
            }

            try await refreshThread(thread, modelContext: modelContext, sessionStore: sessionStore)
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        throw ChatSyncError.pollingTimedOut
    }

    func decidePreparedAction(
        _ actionID: UUID,
        decision: ChatActionDecision,
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        let sessionToken = try sessionToken(from: sessionStore)
        let response = try await api.decidePreparedAction(
            sessionToken: sessionToken,
            id: actionID,
            decision: decision,
            clientMessageID: UUID()
        )
        try merge(response.thread, modelContext: modelContext, preferredThread: thread)
        try modelContext.save()
    }

    @discardableResult
    private func ensureRemoteThread(
        _ thread: ChatThread,
        sessionToken: String,
        modelContext: ModelContext
    ) async throws -> MobileAPIClient.RemoteChatThread {
        if let remoteID = thread.remoteID {
            return try await api.getChatThread(sessionToken: sessionToken, id: remoteID)
        }

        let remoteThread = try await api.createChatThread(
            sessionToken: sessionToken,
            title: thread.title,
            clientThreadID: thread.id
        )
        try merge(remoteThread, modelContext: modelContext, preferredThread: thread)
        try modelContext.save()
        return remoteThread
    }

    private func merge(
        _ remoteThread: MobileAPIClient.RemoteChatThread,
        modelContext: ModelContext,
        preferredThread: ChatThread? = nil
    ) throws {
        let thread = try localThread(
            for: remoteThread,
            modelContext: modelContext,
            preferredThread: preferredThread
        )

        thread.remoteID = remoteThread.id
        thread.title = remoteThread.title.isEmpty ? thread.title : remoteThread.title
        thread.remoteStatusRawValue = remoteThread.status
        thread.syncStatus = .synced
        thread.lastSyncedAt = now()
        thread.updatedAt = remoteThread.updatedAt ?? remoteThread.lastTurnAt ?? thread.updatedAt

        if let pendingRun = remoteThread.pendingRun, pendingRun.runStatus.isPending {
            thread.pendingRunID = pendingRun.id
        } else {
            thread.pendingRunID = nil
        }

        for remoteMessage in remoteMessages(from: remoteThread) {
            try merge(remoteMessage, into: thread, modelContext: modelContext)
        }
    }

    private func remoteMessages(from remoteThread: MobileAPIClient.RemoteChatThread) -> [MobileAPIClient.RemoteChatMessage] {
        var seenIDs = Set<UUID>()
        let messages = remoteThread.messages + (remoteThread.latestMessage.map { [$0] } ?? [])

        return messages.filter { message in
            seenIDs.insert(message.id).inserted
        }
    }

    private func localThread(
        for remoteThread: MobileAPIClient.RemoteChatThread,
        modelContext: ModelContext,
        preferredThread: ChatThread?
    ) throws -> ChatThread {
        if let preferredThread {
            return preferredThread
        }

        let threads = try modelContext.fetch(FetchDescriptor<ChatThread>())
        if let existing = threads.first(where: { $0.remoteID == remoteThread.id }) {
            return existing
        }

        let thread = ChatThread(
            title: remoteThread.title,
            updatedAt: remoteThread.updatedAt ?? remoteThread.lastTurnAt ?? now(),
            remoteID: remoteThread.id,
            remoteStatusRawValue: remoteThread.status,
            syncStatus: .synced,
            lastSyncedAt: now()
        )
        modelContext.insert(thread)
        return thread
    }

    private func merge(
        _ remoteMessage: MobileAPIClient.RemoteChatMessage,
        into thread: ChatThread,
        modelContext: ModelContext
    ) throws {
        let message = localMessage(for: remoteMessage, in: thread) ?? {
            let message = ChatMessage(
                body: remoteMessage.body,
                sentAt: remoteMessage.sentAt ?? now(),
                role: role(from: remoteMessage.role),
                remoteID: remoteMessage.id,
                clientMessageID: remoteMessage.clientMessageID,
                deliveryState: deliveryState(from: remoteMessage.deliveryState),
                turnKind: remoteMessage.turnKind,
                messageClass: remoteMessage.messageClass,
                remoteRunID: remoteMessage.runID,
                thread: thread
            )
            modelContext.insert(message)
            thread.messages.append(message)
            return message
        }()

        message.remoteID = remoteMessage.id
        message.clientMessageID = remoteMessage.clientMessageID ?? message.clientMessageID
        message.body = remoteMessage.body
        message.sentAt = remoteMessage.sentAt ?? message.sentAt
        message.role = role(from: remoteMessage.role)
        message.deliveryState = deliveryState(from: remoteMessage.deliveryState)
        message.turnKind = remoteMessage.turnKind
        message.messageClass = remoteMessage.messageClass
        message.remoteRunID = remoteMessage.runID
        message.structuredData = try encodedMetadata(for: remoteMessage)
    }

    private func localMessage(
        for remoteMessage: MobileAPIClient.RemoteChatMessage,
        in thread: ChatThread
    ) -> ChatMessage? {
        if let match = thread.messages.first(where: { $0.remoteID == remoteMessage.id }) {
            return match
        }

        if let clientMessageID = remoteMessage.clientMessageID {
            return thread.messages.first { $0.clientMessageID == clientMessageID }
        }

        return nil
    }

    private func apply(_ run: MobileAPIClient.RemoteChatRun, to thread: ChatThread) {
        if run.runStatus.isPending {
            thread.pendingRunID = run.id
        } else {
            thread.pendingRunID = nil
        }
        thread.remoteStatusRawValue = run.status
    }

    private func optimisticUserMessage(
        body: String,
        clientMessageID: UUID,
        thread: ChatThread
    ) -> ChatMessage {
        ChatMessage(
            body: body,
            sentAt: now(),
            role: .user,
            clientMessageID: clientMessageID,
            deliveryState: .sending,
            turnKind: "user_message",
            thread: thread
        )
    }

    private func encodedMetadata(for remoteMessage: MobileAPIClient.RemoteChatMessage) throws -> Data {
        let metadata = ChatMessageStoredMetadata(
            actions: remoteMessage.actions.map {
                ChatMessageAction(
                    actionID: $0.id,
                    kind: $0.kind,
                    label: $0.label,
                    decisionRawValue: $0.decision,
                    style: $0.style
                )
            },
            linkedTodo: remoteMessage.linkedTodo,
            structuredData: remoteMessage.structuredData
        )
        return try JSONEncoder().encode(metadata)
    }

    private func sessionToken(from sessionStore: SessionStore) throws -> String {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            throw ChatSyncError.missingSession
        }
        return sessionToken
    }

    private func role(from rawValue: String) -> ChatRole {
        ChatRole(rawValue: rawValue) ?? .assistant
    }

    private func deliveryState(from rawValue: String?) -> ChatDeliveryState {
        ChatDeliveryState(rawValue: rawValue ?? "") ?? .delivered
    }
}
