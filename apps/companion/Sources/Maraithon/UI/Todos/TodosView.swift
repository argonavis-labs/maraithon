import SwiftUI

/// Account-backed work list for the paired Mac. It mirrors the web Todo
/// surface's Gmail-style keyboard workflow while keeping all account data in
/// the main-actor store.
struct TodosView: View {
    @Environment(AppEnvironment.self) private var env

    var initialTodoID: String? = nil
    @State private var workspace: TodoConversationStore?
    @State private var conversations: [String: TodoConversationStore] = [:]
    @State private var activeTodoID: String?
    @State private var markedTodoIDs: Set<String> = []
    @State private var workspaceShown = false
    @State private var shortcutHelpShown = false
    @State private var newTodoShown = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack { todoList }
    }

    @ViewBuilder private var todoList: some View {
        @Bindable var store = env.todos

        VStack(alignment: .leading, spacing: 0) {
            TodosHeaderView(
                store: store,
                showShortcuts: { shortcutHelpShown = true },
                createTodo: { newTodoShown = true }
            )
            Divider()
            TodosFilterView(store: store, searchFocused: $searchFocused)
            Divider()
            content(store: store)
        }
        .navigationTitle("Todos")
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
                openTodo(todo)
                Task { await store.load() }
            }
        }
        .task {
            if store.phase == .idle || store.phase == .loading || initialTodoID != nil { await store.load() }
            if let initialTodoID, let todo = store.todos.first(where: { $0.id == initialTodoID }) { openTodo(todo) }
            reconcileSelection(store.todos)
        }
        .onChange(of: store.todos.map(\.id)) { _, _ in
            reconcileSelection(store.todos)
        }
    }

    private func openTodo(_ todo: CompanionTodo) {
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
        if case .failed(let message) = store.phase, store.todos.isEmpty {
            ContentUnavailableView {
                Label("Todos could not load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await store.load() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.todos.isEmpty, store.phase == .loaded {
            ContentUnavailableView(
                TodosCopy.emptyTitle(filter: store.filter, query: store.query),
                systemImage: store.filter == .active ? "checkmark.circle" : "clock.arrow.circlepath",
                description: Text(TodosCopy.emptyDescription(filter: store.filter, query: store.query))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if case .failed(let message) = store.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(StatusTone.attention.color)
                        .padding(.horizontal, Tokens.Spacing.large)
                        .padding(.vertical, Tokens.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                    Divider()
                }

                List(selection: $activeTodoID) {
                    ForEach(store.todos) { todo in
                        TodoRow(
                            todo: todo,
                            isMarked: markedTodoIDs.contains(todo.id),
                            isWorking: store.pendingActionIDs.contains(todo.id),
                            openAction: { openTodo(todo) },
                            action: {
                                Task {
                                    await store.performPrimaryAction(on: todo)
                                    reconcileSelection(store.todos)
                                }
                            }
                        )
                        .tag(todo.id)
                    }
                }
                .listStyle(.inset)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    handleArrowKey(press, store: store)
                }
                .onKeyPress(.return) {
                    handle(.open, store: store)
                    return .handled
                }
                .onKeyPress(.escape) {
                    let wasShown = workspaceShown
                    handle(.back, store: store)
                    return wasShown ? .handled : .ignored
                }
            }
        }
    }

    private func focusedShortcutActions(store: TodosStore) -> TodoShortcutActions? {
        guard !searchFocused, !shortcutHelpShown else { return nil }
        return TodoShortcutActions { shortcut in
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
            if let todo = activeTodo { openTodo(todo) }
        case .back:
            workspaceShown = false
        case .select:
            toggleActiveTodoMark()
        case .complete:
            perform(.done, store: store)
        case .dismiss:
            perform(.dismiss, store: store)
        case .search:
            searchFocused = true
        case .help:
            shortcutHelpShown = true
        }
    }

    private func handleArrowKey(_ press: KeyPress, store: TodosStore) -> KeyPress.Result {
        switch press.key {
        case .rightArrow, .downArrow:
            moveActiveTodo(by: 1, in: store.todos)
        case .leftArrow, .upArrow:
            moveActiveTodo(by: -1, in: store.todos)
        default:
            return .ignored
        }
        return .handled
    }

    private func moveActiveTodo(by offset: Int, in todos: [CompanionTodo]) {
        guard !todos.isEmpty else { return }
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
        if markedTodoIDs.contains(activeTodoID) {
            markedTodoIDs.remove(activeTodoID)
        } else {
            markedTodoIDs.insert(activeTodoID)
        }
    }

    private func perform(_ action: CompanionTodoAction, store: TodosStore) {
        guard let todo = activeTodo else { return }
        guard action != .done || todo.canMarkDone else { return }
        guard action != .dismiss || todo.canDismiss else { return }

        Task {
            await store.perform(action, on: todo)
            markedTodoIDs.remove(todo.id)
            reconcileSelection(store.todos)
        }
    }

    private func performPrimaryAction(store: TodosStore) {
        guard let todo = activeTodo else { return }
        Task {
            await store.performPrimaryAction(on: todo)
            markedTodoIDs.remove(todo.id)
            reconcileSelection(store.todos)
        }
    }

    private func reconcileSelection(_ todos: [CompanionTodo]) {
        let visibleIDs = Set(todos.map(\.id))
        markedTodoIDs.formIntersection(visibleIDs)

        if let activeTodoID, visibleIDs.contains(activeTodoID) {
            return
        }

        activeTodoID = todos.first?.id
        if activeTodoID == nil {
            workspaceShown = false
        }
    }
}
