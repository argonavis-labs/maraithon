import SwiftUI
import AssistantProgressKit

/// Account-backed work list for the paired Mac. Mirrors the web Tasks page
/// (header, view tabs, search, table) and keeps its Gmail-style keyboard
/// workflow while all account data stays in the main-actor store.
struct TodosView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completion = TodoCompletionFeedback()

    var initialTodoID: String? = nil
    /// Set by the sidebar's "Find a task" row; consumed by focusing search.
    @Binding var searchRequestToken: Int

    @State private var workspace: TodoConversationStore?
    @State private var conversations: [String: TodoConversationStore] = [:]
    @State private var activeTodoID: String?
    @State private var markedTodoIDs: Set<String> = []
    @State private var workspaceShown = false
    @State private var shortcutHelpShown = false
    @State private var newTodoShown = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    init(initialTodoID: String? = nil, searchRequestToken: Binding<Int> = .constant(0)) {
        self.initialTodoID = initialTodoID
        _searchRequestToken = searchRequestToken
    }

    var body: some View {
        NavigationStack { todoList }
    }

    @ViewBuilder private var todoList: some View {
        @Bindable var store = env.todos

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TodosHeaderView(
                        store: store,
                        showShortcuts: { shortcutHelpShown = true },
                        createTodo: { newTodoShown = true }
                    )
                    TodosTabsView(store: store)
                    if store.filter == .triage { TodosQuickEntry(store: store) }
                    TodosFilterView(store: store, searchFocused: $searchFocused)
                    TodosResultLine(store: store)
                    content(store: store)
                }
                .frame(maxWidth: Tokens.Layout.pageMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.Spacing.page)
                .padding(.top, Tokens.Layout.pageTopInset)
                .padding(.bottom, Tokens.Spacing.page)
            }
            .background(Tokens.Palette.background)
            .onChange(of: activeTodoID) { _, id in
                guard let id, listFocused else { return }
                proxy.scrollTo(id, anchor: nil)
            }
        }
        .focusedSceneValue(\.todoShortcutActions, (newTodoShown || workspaceShown) ? nil : focusedShortcutActions(store: store))
        .navigationDestination(isPresented: $workspaceShown) {
            if let workspace { TodoWorkspaceView(store: workspace) }
        }
        .onChange(of: env.deviceAuth.currentToken) { _, _ in
            workspaceShown = false
            workspace = nil
            conversations = [:]
        }
        .sheet(isPresented: $shortcutHelpShown) {
            TodoShortcutHelpView()
        }
        .sheet(isPresented: $newTodoShown) {
            NewTodoView(store: store) { todo in
                openTodo(todo, via: "new_todo")
                Task { await store.load() }
            }
        }
        .modifier(TodosAutoRefresh(store: store, isEnabled: !workspaceShown && !newTodoShown))
        .task {
            if initialTodoID != nil { await store.load() }
            if let initialTodoID, let todo = store.todos.first(where: { $0.id == initialTodoID }) { openTodo(todo, via: "initial_todo_id") }
            reconcileSelection(store.todos)
        }
        .onChange(of: store.todos.map(\.id)) { previousIDs, _ in
            reconcileSelection(store.todos, previousIDs: previousIDs)
        }
        .task(id: searchRequestToken) {
            guard searchRequestToken > 0 else { return }
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
            searchRequestToken = 0
        }
    }

    private func openTodo(_ todo: CompanionTodo, via: String = "unknown") {
        env.eventLog.debug("todos.open_todo", source: .ui, payload: ["todo_id": todo.id, "via": via])
        activeTodoID = todo.id
        let existing = conversations[todo.id]
        let session = existing ?? TodoConversationStore(todo: todo, client: MaraithonClient(
            tokenProvider: { [weak auth = env.deviceAuth] in
                await MainActor.run { [auth] in auth?.currentToken }
            }
        ))
        conversations[todo.id] = session
        workspace = session
        workspaceShown = true
    }

    private var activeTodo: CompanionTodo? {
        guard let activeTodoID else { return nil }
        return env.todos.todos.first(where: { $0.id == activeTodoID })
    }

    @ViewBuilder
    private func content(store: TodosStore) -> some View {
        VStack(spacing: 0) {
            if case .failed(let message) = store.phase, !store.todos.isEmpty {
                TodosNoticeRow(message: message) { Task { await store.load() } }
            }

            TodoTableHeader(
                allSelected: !store.todos.isEmpty && markedTodoIDs.isSuperset(of: store.todos.map(\.id)),
                hasRows: !store.todos.isEmpty,
                toggleAll: { toggleAllMarks(store: store) }
            )

            if case .failed(let message) = store.phase, store.todos.isEmpty {
                TodosEmptyView(
                    title: "Tasks could not load",
                    description: message,
                    actionTitle: "Retry",
                    action: { Task { await store.load() } }
                )
            } else if store.todos.isEmpty, store.phase == .loaded {
                TodosEmptyView(
                    title: TodosCopy.emptyTitle(filter: store.filter, query: store.query),
                    description: TodosCopy.emptyDescription(filter: store.filter, query: store.query)
                )
            } else if store.todos.isEmpty {
                TodosEmptyView(title: "Loading tasks", description: "Pulling the latest work from your account.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.todos) { todo in
                        TodoRow(
                            todo: todo,
                            isActive: activeTodoID == todo.id,
                            isMarked: markedTodoIDs.contains(todo.id),
                            isWorking: store.pendingActionIDs.contains(todo.id),
                            isCompleting: completion.confirmedIDs.contains(todo.id),
                            select: {
                                activeTodoID = todo.id
                                listFocused = true
                            },
                            openAction: { openTodo(todo, via: "row") },
                            action: { perform(todo.canReopen ? .reopen : .done, on: todo, store: store) },
                            accept: { perform(.accept, on: todo, store: store) },
                            ignore: { perform(.ignore, on: todo, store: store) }
                        )
                        .id(todo.id)
                        .transition(.opacity)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard !searchFocused, press.modifiers.isEmpty else { return .ignored }
                    let offset = [.leftArrow, .upArrow].contains(press.key) ? -1 : 1
                    moveActiveTodo(by: offset, in: store.todos)
                    return .handled
                }
                .onKeyPress(.space, phases: .down) { press in
                    guard !searchFocused, !store.quickEntryFocused, !store.quickCapturePresented, press.modifiers.isEmpty,
                          activeTodo != nil else { return .ignored }
                    handle(.complete, store: store)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard !searchFocused else { return .ignored }
                    env.eventLog.debug("todos.return_key", source: .ui)
                    handle(.open, store: store)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !searchFocused else { return .ignored }
                    let wasShown = workspaceShown
                    handle(.back, store: store)
                    return wasShown ? .handled : .ignored
                }
            }
        }
        .animation(reduceMotion ? nil : .default, value: store.todos.map(\.id))
    }

    private func focusedShortcutActions(store: TodosStore) -> TodoShortcutActions? {
        guard !searchFocused, !store.quickEntryFocused, !store.quickCapturePresented, !shortcutHelpShown else { return nil }
        return TodoShortcutActions(isTriage: store.filter == .triage) { shortcut in
            handle(shortcut, store: store)
        }
    }

    private func handle(_ shortcut: TodoShortcut, store: TodosStore) {
        switch shortcut {
        case .next:
            moveActiveTodo(by: 1, in: store.todos)
        case .previous:
            moveActiveTodo(by: -1, in: store.todos)
        case .open:
            if let todo = activeTodo { openTodo(todo, via: "shortcut_open") }
        case .back:
            workspaceShown = false
        case .select:
            toggleActiveTodoMark()
        case .complete:
            perform(.done, store: store)
        case .dismiss:
            perform(store.filter == .triage ? .ignore : .dismiss, store: store)
        case .search:
            searchFocused = true
        case .help:
            shortcutHelpShown = true
        }
    }

    private func moveActiveTodo(by offset: Int, in todos: [CompanionTodo]) {
        guard !todos.isEmpty else { return }
        listFocused = true
        guard let activeTodoID,
              let index = todos.firstIndex(where: { $0.id == activeTodoID }) else {
            self.activeTodoID = todos.first?.id
            return
        }

        let targetIndex = index + offset
        guard todos.indices.contains(targetIndex) else { return }
        self.activeTodoID = todos[targetIndex].id
    }

    private func toggleActiveTodoMark() {
        guard let activeTodoID else { return }
        toggleMark(activeTodoID)
    }

    private func toggleMark(_ id: String) {
        if markedTodoIDs.contains(id) {
            markedTodoIDs.remove(id)
        } else {
            markedTodoIDs.insert(id)
        }
    }

    private func toggleAllMarks(store: TodosStore) {
        let visible = Set(store.todos.map(\.id))
        if markedTodoIDs.isSuperset(of: visible), !visible.isEmpty {
            markedTodoIDs.subtract(visible)
        } else {
            markedTodoIDs.formUnion(visible)
        }
    }

    private func perform(_ action: CompanionTodoAction, store: TodosStore) {
        guard let todo = activeTodo else { return }
        guard action != .done || todo.isInTriage || todo.canMarkDone else { return }
        guard action != .dismiss || todo.canDismiss else { return }

        perform(action, on: todo, store: store)
    }

    private func perform(_ action: CompanionTodoAction, on todo: CompanionTodo, store: TodosStore) {
        guard completion.begin(todo.id) else { return }
        let previousIDs = store.todos.map(\.id)
        Task {
            defer { completion.finish(todo.id) }
            await store.perform(action, on: todo) {
                await completion.confirm(todo.id, reduceMotion: reduceMotion)
            }
            markedTodoIDs.remove(todo.id)
            reconcileSelection(store.todos, previousIDs: previousIDs)
        }
    }

    private func reconcileSelection(_ todos: [CompanionTodo], previousIDs: [String] = []) {
        let visibleIDs = Set(todos.map(\.id))
        markedTodoIDs.formIntersection(visibleIDs)
        if let activeTodoID, visibleIDs.contains(activeTodoID) {
            return
        }
        let index = activeTodoID.flatMap { previousIDs.firstIndex(of: $0) } ?? 0
        activeTodoID = todos.isEmpty ? nil : todos[min(index, todos.count - 1)].id
        if activeTodoID == nil { workspaceShown = false }
    }
}
