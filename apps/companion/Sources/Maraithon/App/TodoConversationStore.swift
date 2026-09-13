/// Owns one todo workspace. Network retries retain the exact message ID; the
/// server owns execution. A message written while a run is active waits in a
/// local queue and is sent, unchanged, when that run settles.
import AssistantProgressKit
import Foundation
import Observation

@Observable @MainActor
final class TodoConversationStore {
    var todo: CompanionTodo
    var composer = ""
    /// The live review the user chose to open in the work column.
    var preferredReviewID: String?
    private(set) var thread: CompanionConversation?
    private(set) var run: CompanionConversation.Run?
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var decidingActionID: String?
    private(set) var error: String?
    private(set) var connectionNotice: String?
    private(set) var pendingMessage: PendingMessage?
    private(set) var queuedMessage: PendingMessage?
    var draftEdits: [String: DraftEdits] = [:]
    struct DraftEdits: Equatable {
        var recipient: String
        var subject: String
        var body: String
        var cc: String
        var bcc: String
    }
    private var progressCursor: String?
    private var runAwaitingResult: String?
    private let client: MaraithonClient

    struct PendingMessage {
        let id: String
        let body: String
    }

    init(todo: CompanionTodo, client: MaraithonClient) {
        self.todo = todo
        self.client = client
    }

    var isThinking: Bool { run?.isActive == true || thread?.pendingRun?.isActive == true }

    var runStartedAt: Date? {
        CompanionConversation.date(from: run?.startedAt ?? thread?.pendingRun?.startedAt)
    }

    /// Turns worth rendering: user and assistant turns with words, work, or a
    /// draft. The primer only appears for its draft; its summary leads the work column.
    var visibleMessages: [CompanionConversation.Message] {
        (thread?.messages ?? []).filter { message in
            guard ["user", "assistant"].contains(message.role) else { return false }
            let hasCard = message.draftCard != nil
            if message.isPrimer { return hasCard }
            let hasBody = !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasWork = !(message.workSummary?.toolCalls ?? []).isEmpty
            return hasBody || hasWork || hasCard
        }
    }

    func connectAndObserve() async {
        await load()
        var failures = 0
        while !Task.isCancelled, let threadID = thread?.id {
            do {
                try await client.observeConversation(id: threadID, cursor: progressCursor) { event in
                    try await self.receive(event)
                }
                failures = 0
                connectionNotice = nil
                try await Task.sleep(for: .milliseconds(500))
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                failures += 1
                connectionNotice = "Connection interrupted. Reconnecting…"
                // Old deployments and interrupted streams can still reconcile
                // through the ordinary read endpoint. This never starts work.
                progressCursor = nil
                try? await refresh()
                do { try await Task.sleep(for: .seconds(min(30, 2 * failures))) }
                catch { return }
            }
        }
    }

    private func receive(_ event: AssistantProgress<CompanionConversation>) async throws {
        try Task.checkCancellation()
        switch event {
        case .snapshot(let snapshot):
            guard snapshot.thread.id == thread?.id else { return }
            let wasThinking = isThinking
            let previousRun = run
            apply(.init(thread: snapshot.thread, run: nil))
            keepLivePreview(from: previousRun)
            progressCursor = snapshot.cursor
            connectionNotice = nil
            try await settleFinishedRun()
            if (wasThinking && !isThinking) || workflowChanged { await refreshTodo() }
            await flushQueueIfIdle()
        case .preview(let preview):
            guard preview.threadID == thread?.id, let run, run.id == preview.runID, run.isActive else { return }
            self.run = run.withPreview(preview.reply)
        }
    }

    /// Snapshots drop streamed text from their durable cursor. Keep the last
    /// reply for the same live run so it does not blink away between frames.
    private func keepLivePreview(from previous: CompanionConversation.Run?) {
        guard let previous, let current = run, current.id == previous.id, current.isActive,
              current.workSummary?.preview == nil, let preview = previous.workSummary?.preview else { return }
        run = current.withPreview(preview)
    }

    private var workflowChanged: Bool {
        guard let linked = thread?.linkedTodo, linked.id == todo.id else { return false }
        return linked.workflow != todo.workflow
    }

    private func settleFinishedRun() async throws {
        guard run == nil, let runID = runAwaitingResult else { return }
        let finished = try await client.conversationRun(id: runID)
        try Task.checkCancellation()
        guard runAwaitingResult == runID, !finished.isActive else { return }
        runAwaitingResult = nil
        if let failure = finished.error { error = failure }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response = try await client.todoConversation(id: todo.id)
            try Task.checkCancellation()
            apply(response)
            try? await client.markTodoOpened(id: todo.id)
            await refreshTodo()
        } catch is CancellationError { }
        catch { self.error = CompanionErrorCopy.message(for: error) }
    }

    /// Sends the composer text, or `suggestion` when given. While Maraithon is
    /// still working the message waits in the queue instead of failing.
    func send(_ suggestion: String? = nil) async {
        guard thread != nil else { return }
        let body = (suggestion ?? composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if suggestion == nil { composer = "" }
        if isSending || pendingMessage != nil || isThinking {
            enqueue(body)
            return
        }
        pendingMessage = PendingMessage(id: UUID().uuidString.lowercased(), body: body)
        await retrySend()
    }

    func removeQueuedMessage() {
        queuedMessage = nil
    }

    private func enqueue(_ body: String) {
        if let queued = queuedMessage {
            queuedMessage = PendingMessage(id: queued.id, body: queued.body + "\n\n" + body)
        } else {
            queuedMessage = PendingMessage(id: UUID().uuidString.lowercased(), body: body)
        }
    }

    private func flushQueueIfIdle() async {
        guard let queued = queuedMessage, pendingMessage == nil, !isSending, !isThinking else { return }
        queuedMessage = nil
        pendingMessage = queued
        await retrySend()
    }

    func retrySend() async {
        guard let thread, let pendingMessage, !isSending else { return }
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            let response = try await client.sendConversationMessage(threadID: thread.id,
                clientID: pendingMessage.id, body: pendingMessage.body)
            self.pendingMessage = nil
            apply(response)
        } catch { self.error = "Message not confirmed. Retry safely with the same message. " + CompanionErrorCopy.message(for: error) }
    }

    func decide(id: String, decision: String, edits: [String: String]) async {
        guard decidingActionID == nil else { return }
        decidingActionID = id
        error = nil
        defer { decidingActionID = nil }
        do {
            apply(try await client.decideConversationAction(id: id, decision: decision, edits: edits))
            await refreshTodo()
        } catch {
            self.error = CompanionErrorCopy.message(for: error)
            // A timeout does not mean the provider failed. Reconcile the same action.
            try? await refresh()
        }
    }

    func transitionWorkflow(_ change: TodoWorkflowChange) async throws {
        todo = try await client.transitionTodo(id: todo.id, change: change).todo
        await refreshTodo()
    }

    func refreshTodo() async {
        if let details = try? await client.todoDetails(id: todo.id) { todo = details.todo }
    }

    private func refresh() async throws {
        guard let thread else { return }
        let wasThinking = isThinking
        if let run, run.isActive { self.run = try await client.conversationRun(id: run.id) }
        let response = try await client.conversation(id: thread.id)
        try Task.checkCancellation()
        apply(response)
        if (wasThinking && !isThinking) || workflowChanged || todo.brief == nil { await refreshTodo() }
        await flushQueueIfIdle()
    }

    private func apply(_ response: CompanionConversation.Response) {
        // A REST mutation can race a streamed snapshot. Only resume from a
        // cursor whose snapshot is still the state displayed by this store.
        progressCursor = nil
        thread = response.thread
        if let pendingMessage, response.thread.messages.contains(where: { $0.clientMessageID == pendingMessage.id }) {
            self.pendingMessage = nil
            error = nil
        }
        run = response.run ?? response.thread.pendingRun
        if let run, run.isActive { runAwaitingResult = run.id }
        if run?.isActive == false, let failure = run?.error { error = failure }
    }
}
