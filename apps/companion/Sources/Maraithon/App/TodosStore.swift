import AssistantProgressKit
import Foundation
import Observation

/// Main-actor state for the account-backed Todo list. It keeps paired-device
/// data in memory only and clears it immediately when auth is rejected.
@Observable
@MainActor
final class TodosStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    typealias UnauthorizedHandler = @MainActor @Sendable () -> Void

    private(set) var todos: [CompanionTodo] = []
    private(set) var phase: Phase = .idle
    private(set) var pendingActionIDs: Set<String> = []
    private(set) var lastUpdatedAt: Date?
    private(set) var loadingDetailIDs: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    var filter: TodoListFilter = .triage {
        didSet {
            guard filter != oldValue else { return }
            needsInitialView = false
            loadGeneration += 1
            todos = []
            phase = .idle
        }
    }
    var category: TaskCategory = .all {
        didSet {
            guard category != oldValue else { return }
            loadGeneration += 1
            todos = []
            phase = .idle
        }
    }
    var quickEntryFocused = false
    var quickCapturePresented = false
    var query: String = ""

    private let client: MaraithonClient
    private let eventLog: EventLog
    private let unauthorizedHandler: UnauthorizedHandler
    private var loadGeneration = 0
    private var loadingGeneration: Int?
    private var submittedQuery: String?
    private var accountGeneration = 0
    private var needsInitialView = true
    private var detailRequestTokens: [String: UUID] = [:]

    init(
        client: MaraithonClient,
        eventLog: EventLog,
        unauthorizedHandler: @escaping UnauthorizedHandler
    ) {
        self.client = client
        self.eventLog = eventLog
        self.unauthorizedHandler = unauthorizedHandler
    }

    var isLoading: Bool {
        loadingGeneration != nil
    }

    func create(_ draft: CompanionTodoDraft, stayInTriage: Bool = false) async throws -> CompanionTodo {
        let generation = accountGeneration
        eventLog.debug("todos.create_started", source: .cloud)
        do {
            let response = try await client.createTodo(draft)
            guard generation == accountGeneration else { throw CancellationError() }
            loadGeneration += 1
            if !stayInTriage {
                if filter != .active || normalizedQuery != nil { todos = [] }
                filter = .active
                category = .all
                query = ""
                submittedQuery = nil
            }
            apply(response.todo)
            phase = .loaded
            eventLog.info("todos.create_finished", source: .cloud, payload: ["todo_id": response.todo.id])
            return response.todo
        } catch MaraithonClientError.unauthorized {
            if generation == accountGeneration { rejectToken() }
            throw MaraithonClientError.unauthorized
        } catch {
            eventLog.warning("todos.create_failed", source: .cloud)
            throw error
        }
    }

    func load(automatically: Bool = false) async {
        guard !Task.isCancelled else { return }
        if automatically {
            guard !isLoading, pendingActionIDs.isEmpty, loadingDetailIDs.isEmpty,
                  normalizedQuery == submittedQuery else { return }
        }
        loadGeneration += 1
        let generation = loadGeneration
        loadingGeneration = generation
        defer { if loadingGeneration == generation { loadingGeneration = nil } }
        let requestedFilter = filter
        let requestedQuery = normalizedQuery
        submittedQuery = requestedQuery
        if !automatically || phase == .idle { phase = .loading }
        eventLog.debug("todos.load_started", source: .cloud, payload: ["filter": requestedFilter.rawValue])

        do {
            let response = try await client.listTodos(
                filter: requestedFilter,
                query: requestedQuery,
                category: category.rawValue
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }

            if needsInitialView {
                needsInitialView = false
                if requestedFilter == .triage, requestedQuery == nil, category == .all,
                   response.todos.isEmpty {
                    filter = .active
                    await load()
                    return
                }
            }

            todos = response.todos
            detailErrors = [:]
            lastUpdatedAt = Date()
            phase = .loaded
            eventLog.info("todos.load_finished", source: .cloud, payload: [
                "filter": requestedFilter.rawValue, "count": String(response.todos.count)
            ])
        } catch MaraithonClientError.unauthorized {
            guard generation == loadGeneration else { return }
            rejectToken()
        } catch {
            guard generation == loadGeneration else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if !automatically || phase == .loading { phase = todos.isEmpty ? .idle : .loaded }
                eventLog.debug("todos.load_cancelled", source: .cloud)
                return
            }
            let message = CompanionErrorCopy.message(for: error)
            phase = .failed(message: message)
            eventLog.warning("todos.load_failed", source: .cloud, payload: ["error": String(describing: error)])
        }
    }

    func sendReply(for todo: CompanionTodo, body: String, subject: String) async throws {
        let generation = accountGeneration
        eventLog.debug("todos.reply_started", source: .cloud, payload: ["todo_id": todo.id])
        do {
            let response = try await client.sendTodoReply(id: todo.id, body: body, subject: subject)
            guard generation == accountGeneration else { throw CancellationError() }
            apply(response.todo)
            eventLog.info("todos.reply_sent", source: .cloud, payload: ["todo_id": todo.id])
        } catch MaraithonClientError.unauthorized {
            if generation == accountGeneration { rejectToken() }
            throw MaraithonClientError.unauthorized
        } catch {
            eventLog.warning("todos.reply_failed", source: .cloud, payload: ["todo_id": todo.id])
            throw error
        }
    }

    func loadDetails(for todo: CompanionTodo) async {
        guard todo.actionCard == nil || todo.brief == nil else { return }
        let generation = loadGeneration
        let requestToken = UUID()
        detailRequestTokens[todo.id] = requestToken
        loadingDetailIDs.insert(todo.id)
        detailErrors.removeValue(forKey: todo.id)
        eventLog.debug("todos.details_started", source: .cloud, payload: ["todo_id": todo.id])

        defer {
            if detailRequestTokens[todo.id] == requestToken {
                detailRequestTokens.removeValue(forKey: todo.id)
                loadingDetailIDs.remove(todo.id)
            }
        }

        do {
            try await client.markTodoOpened(id: todo.id)
            var response = try await client.todoDetails(id: todo.id)
            for _ in 0..<6 where response.todo.brief == nil && response.todo.canMarkDone {
                try await Task.sleep(for: .seconds(5))
                response = try await client.todoDetails(id: todo.id)
            }
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  detailRequestTokens[todo.id] == requestToken,
                  todos.first(where: { $0.id == todo.id }) == todo else { return }
            apply(response.todo)
            eventLog.debug("todos.details_finished", source: .cloud, payload: ["todo_id": todo.id])
        } catch MaraithonClientError.unauthorized {
            guard !Task.isCancelled, generation == loadGeneration,
                  detailRequestTokens[todo.id] == requestToken else { return }
            rejectToken()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration,
                  detailRequestTokens[todo.id] == requestToken else { return }
            detailErrors[todo.id] = CompanionErrorCopy.message(for: error)
            eventLog.warning("todos.details_failed", source: .cloud, payload: ["todo_id": todo.id])
        }
    }

    func performPrimaryAction(on todo: CompanionTodo, onCompleted: (() async -> Void)? = nil) async {
        guard todo.isInTriage || todo.canMarkDone || todo.canReopen else { return }
        let action: CompanionTodoAction = todo.isInTriage ? .accept : (todo.canMarkDone ? .done : .reopen)
        await perform(action, on: todo, onCompleted: onCompleted)
    }

    func perform(_ action: CompanionTodoAction, on todo: CompanionTodo, onCompleted: (() async -> Void)? = nil) async {
        guard !pendingActionIDs.contains(todo.id) else { return }
        let generation = accountGeneration
        pendingActionIDs.insert(todo.id)
        defer { if generation == accountGeneration { pendingActionIDs.remove(todo.id) } }

        do {
            let response = try await client.updateTodo(id: todo.id, action: action)
            guard generation == accountGeneration else { return }
            loadGeneration += 1
            if action == .done, response.todo.status == "done" { await onCompleted?() }
            guard generation == accountGeneration else { return }
            apply(response.todo)
            phase = .loaded
            eventLog.info(
                "todos.action_finished",
                source: .cloud,
                payload: ["action": action.rawValue, "todo_id": todo.id]
            )
        } catch MaraithonClientError.unauthorized {
            if generation == accountGeneration { rejectToken() }
        } catch {
            guard generation == accountGeneration else { return }
            phase = .failed(message: CompanionErrorCopy.message(for: error))
            eventLog.warning(
                "todos.action_failed",
                source: .cloud,
                payload: [
                    "action": action.rawValue,
                    "todo_id": todo.id,
                    "error": String(describing: error)
                ]
            )
        }
    }

    func clear() {
        accountGeneration += 1
        loadGeneration += 1
        loadingGeneration = nil
        submittedQuery = nil
        todos = []
        pendingActionIDs = []
        loadingDetailIDs = []
        detailErrors = [:]
        detailRequestTokens = [:]
        lastUpdatedAt = nil
        phase = .idle
        filter = .triage
        needsInitialView = true
        category = .all
        query = ""
    }

    private var normalizedQuery: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func apply(_ todo: CompanionTodo) {
        // An older list response must never undo a completed action.
        loadGeneration += 1
        if phase == .loading { phase = .loaded }
        if filter.includes(todo) && category.includes(todo.accountCategory) {
            if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                todos[index] = todo
            } else {
                todos.insert(todo, at: 0)
            }
        } else {
            todos.removeAll { $0.id == todo.id }
        }
        lastUpdatedAt = Date()
    }
    private func rejectToken() {
        clear()
        eventLog.warning("todos.unauthorized", source: .auth)
        unauthorizedHandler()
    }
}
