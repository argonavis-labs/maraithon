import SwiftData
import SwiftUI
import UIKit
import AssistantProgressKit

struct TodosView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \TodoItem.updatedAt, order: .reverse) private var todos: [TodoItem]
    @State private var filter: TodoFilter = .triage
    @State private var needsInitialView = true
    @State private var category: TaskCategory = .all
    @State private var searchText = ""
    @State private var isAddingTodo = false
    @State private var editingTodo: TodoItem?
    @State private var linkedTodo: TodoItem?
    @State private var actionErrorMessage: String?
    @State private var refreshErrorMessage: String?
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var workLists: TodoWorkLists?
    @State private var completion = TodoCompletionFeedback()

    private static let rowInsets = EdgeInsets(
        top: Runner.Spacing.tight,
        leading: Runner.Layout.pageInset,
        bottom: Runner.Spacing.tight,
        trailing: Runner.Layout.pageInset
    )

    private var isVisible: Bool {
        scenePhase == .active && appNavigation.selectedTab == .todos
    }

    private var emptyState: TodoEmptyState {
        filter.emptyState(searchText: searchText, hasAnyWork: !todos.isEmpty)
    }

    /// Cheap content fingerprint compared in `onChange`; identity-based array
    /// equality would miss in-place edits like completing a todo.
    private var todoSignature: Int {
        TodoListSignature.signature(for: todos)
    }

    private var currentWorkLists: TodoWorkLists {
        workLists ?? TodoWorkLists(todos: todos, filter: filter, searchText: searchText, category: category)
    }

    var body: some View {
        let lists = currentWorkLists
        NavigationStack {
            VStack(spacing: 0) {
                if isRefreshing {
                    ProgressView("Refreshing todos")
                        .controlSize(.small)
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Runner.Layout.pageInset)
                        .padding(.vertical, Runner.Spacing.small)
                }

                if let refreshErrorMessage {
                    SyncIssueBanner(
                        message: refreshErrorMessage,
                        retry: { Task { await refreshLatestWork(force: true) } },
                        dismiss: { self.refreshErrorMessage = nil }
                    )
                }

                if let actionErrorMessage {
                    SyncIssueBanner(
                        title: TodosViewCopy.actionWarningTitle,
                        message: actionErrorMessage,
                        buttonTitle: nil,
                        retry: nil,
                        dismissAccessibilityLabel: TodosViewCopy.dismissActionWarningAccessibilityLabel,
                        dismiss: { self.actionErrorMessage = nil }
                    )
                }

                RunnerPageHeader(
                    eyebrow: "Your workspace",
                    title: filter == .triage ? "Triage" : "Todos",
                    count: lists.filtered.count,
                    subtitle: filter == .triage ? "Choose what belongs on your list." : filter == .tracking
                        ? "Work that matters to you, owned by someone else."
                        : "A clear next step for everything on your plate."
                ) {
                    HStack(spacing: Runner.Spacing.small) {
                        AccountMenuButton()
                        Button {
                            isAddingTodo = true
                        } label: {
                            Label("New task", systemImage: "plus")
                        }
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                        .accessibilityLabel("Add todo")
                    }
                }
                .padding(.horizontal, Runner.Layout.pageInset)
                .padding(.top, Runner.Spacing.small)

                RunnerTabs(items: filterTabs(counts: lists.counts), selection: Binding(
                    get: { filter },
                    set: { needsInitialView = false; filter = $0 }
                ))
                if filter == .triage {
                    TodoQuickEntry(create: quickAdd)
                        .padding(.horizontal, Runner.Layout.pageInset)
                        .padding(.vertical, Runner.Spacing.small)
                }

                Picker("Personal or work", selection: $category) {
                    ForEach(TaskCategory.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Runner.Layout.pageInset)
                .padding(.top, Runner.Spacing.small)

                RunnerSearchField(placeholder: filter.searchPrompt, text: $searchText)
                    .padding(.horizontal, Runner.Layout.pageInset)
                    .padding(.vertical, Runner.Spacing.tight)

                List {
                    if filter != .open && filter != .triage {
                        HStack {
                            Text(filter.title)
                                .font(Runner.Typography.small)
                                .foregroundStyle(Runner.Palette.mutedForeground)
                            Spacer()
                            Button("Show Todos") { filter = .open }
                                .buttonStyle(RunnerButtonStyle(.plain, compact: true))
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Runner.Palette.background)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: Runner.Layout.pageInset,
                            bottom: 0,
                            trailing: Runner.Layout.pageInset
                        ))
                    }

                    if lists.filtered.isEmpty && !isRefreshing {
                        RunnerEmptyState(
                            title: emptyState.title,
                            description: emptyState.description,
                            systemImage: emptyState.systemImage
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Runner.Palette.background)
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(lists.filtered) { todo in
                            if todo.isInTriage {
                                TriageTodoRow(todo: todo,
                                    isWorking: completion.pendingIDs.contains(todo.id.uuidString),
                                    isCompleting: completion.confirmedIDs.contains(todo.id.uuidString),
                                    open: { linkedTodo = todo },
                                    complete: { decideTriage(todo, action: "done") },
                                    accept: { decideTriage(todo, action: "accept") },
                                    ignore: { decideTriage(todo, action: "see_less") })
                                    .listRowInsets(Self.rowInsets)
                                    .listRowBackground(completion.confirmedIDs.contains(todo.id.uuidString)
                                        ? Runner.Palette.success.opacity(0.08) : Runner.Palette.background)
                                    .listRowSeparatorTint(Runner.Palette.border)
                                    .transition(.opacity)
                            } else {
                            NavigationLink {
                                TodoDetailView(todo: todo)
                            } label: {
                                TodoRow(todo: todo,
                                    isWorking: completion.pendingIDs.contains(todo.id.uuidString),
                                    isCompleting: completion.confirmedIDs.contains(todo.id.uuidString)) {
                                    toggle(todo)
                                }
                            }
                            .listRowInsets(Self.rowInsets)
                            .listRowBackground(completion.confirmedIDs.contains(todo.id.uuidString)
                                ? Runner.Palette.success.opacity(0.08) : Runner.Palette.background)
                            .listRowSeparatorTint(Runner.Palette.border)
                            .transition(.opacity)
                            .swipeActions(edge: .leading) {
                                Button {
                                    toggle(todo)
                                } label: {
                                    Label(
                                        todo.isCompleted ? "Reopen" : "Complete",
                                        systemImage: todo.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle"
                                    )
                                }
                                .tint(todo.isCompleted ? Runner.Palette.caution : Runner.Palette.success)

                                if todo.attentionMode == .monitor, todo.isActive, !todo.isOwnedBySomeoneElse {
                                    Button {
                                        markNeedsAction(todo)
                                    } label: {
                                        Label("Act now", systemImage: "exclamationmark.circle")
                                    }
                                    .tint(Runner.Palette.info)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if todo.isActive {
                                    Button {
                                        ignore(todo)
                                    } label: {
                                        Label("Ignore", systemImage: "hand.thumbsdown")
                                    }
                                    .tint(Runner.Palette.caution)
                                    .accessibilityHint("Teaches Maraithon to show fewer todos like this")
                                } else {
                                    Button(role: .destructive) {
                                        delete(todo)
                                    } label: {
                                        Label(TodosViewCopy.dismissActionLabel, systemImage: "trash")
                                    }
                                    .tint(Runner.Palette.destructive)
                                }

                                Button {
                                    editingTodo = todo
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(Runner.Palette.info)

                                if todo.status == .open {
                                    Button {
                                        snooze(todo)
                                    } label: {
                                        Label("Snooze", systemImage: "clock")
                                    }
                                    .tint(Runner.Palette.caution)
                                }
                            }
                            .disabled(completion.pendingIDs.contains(todo.id.uuidString))
                            }
                        }
                        .onDelete(perform: deleteTodos)
                    }
                }
                .listStyle(.plain)
                .animation(reduceMotion ? nil : .default, value: lists.filtered.map(\.id))
            }
            .runnerPage()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isAddingTodo) {
                TodoEditorView()
            }
            .sheet(item: $editingTodo) { todo in
                TodoEditorView(todo: todo)
            }
            .navigationDestination(item: $linkedTodo) { todo in
                TodoDetailView(todo: todo)
            }
            .task(id: appNavigation.requestedTodoID) {
                await openRequestedTodoIfNeeded()
            }
            .onChange(of: todoSignature) { _, _ in
                rebuildWorkLists()
            }
            .onChange(of: searchText) { _, _ in
                rebuildWorkLists()
            }
            .onChange(of: category) { _, _ in rebuildWorkLists() }
            .onChange(of: filter) { _, _ in
                rebuildWorkLists()
            }
            .refreshable {
                // An explicit pull is a demand for fresh data; bypass the
                // conditional (ETag) fast path.
                await refreshLatestWork(force: true)
            }
            .onAppear(perform: applyRequestedFilterIfNeeded)
            .onChange(of: appNavigation.requestedTodoFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            rebuildWorkLists()
            await refreshLatestWork()
            if !Task.isCancelled, needsInitialView, refreshErrorMessage == nil, linkedTodo == nil {
                needsInitialView = false
                let savedTodos = (try? modelContext.fetch(FetchDescriptor<TodoItem>())) ?? todos
                filter = savedTodos.contains(where: \.isInTriage) ? .triage : .open
                rebuildWorkLists()
            }
        }
        .sensoryFeedback(.success, trigger: completion.successCount)
    }

    private func filterTabs(counts: TodoFilterCounts) -> [RunnerTabs<TodoFilter>.Item] {
        ([TodoFilter.triage, .open] + TodoFilter.allCases).map { option in
            RunnerTabs<TodoFilter>.Item(id: option, title: option.title, count: counts.value(for: option))
        }
    }

    private func rebuildWorkLists() {
        workLists = TodoWorkLists(todos: todos, filter: filter, searchText: searchText, category: category)
    }

    private func refreshLatestWork(force: Bool = false) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        // A page-by-page sync belongs to the saved collection, not the visible
        // list. SwiftUI cancels its .task when a row opens or the tab changes;
        // an independently owned task lets the remaining pages finish saving.
        // Returning to Todos or pulling to refresh joins that same operation.
        let task = Task { @MainActor in
            isRefreshing = true
            refreshErrorMessage = nil
            defer {
                isRefreshing = false
                refreshTask = nil
            }

            do {
                try await ProductionDataSync.refreshTodos(
                    sessionStore: sessionStore,
                    modelContext: modelContext,
                    includeCards: true,
                    force: force
                )
            } catch is CancellationError {
                // Session changes stop the merge without reporting a failure
                // against the newly signed-in user's list.
            } catch {
                guard !Task.isCancelled else { return }
                refreshErrorMessage = "Could not refresh todos. \(MobileErrorCopy.message(for: error))"
            }
        }
        refreshTask = task
        await task.value
    }

    private func toggle(_ todo: TodoItem) {
        let id = todo.id.uuidString
        guard completion.begin(id) else { return }
        let completed = !todo.isCompleted
        actionErrorMessage = nil

        guard let sessionToken = sessionStore.user?.sessionToken else {
            withAnimation(reduceMotion ? nil : .default) {
                todo.setCompleted(completed)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.localUpdateFailedMessage)
                rebuildWorkLists()
            }
            completion.finish(id)
            return
        }
        Task { @MainActor in
            defer { completion.finish(id) }
            do {
                let remote = if completed {
                    try await MobileAPIClient().performTodoAction(
                        sessionToken: sessionToken,
                        id: todo.id,
                        action: "done"
                    )
                } else {
                    try await MobileAPIClient().updateTodo(
                        sessionToken: sessionToken,
                        id: todo.id,
                        payload: ["status": .string("open")]
                    )
                }
                guard sessionStore.user?.sessionToken == sessionToken, todo.modelContext != nil else { return }
                if completed, remote.status == "done" {
                    await completion.confirm(id, reduceMotion: reduceMotion)
                }
                guard sessionStore.user?.sessionToken == sessionToken, todo.modelContext != nil else { return }
                withAnimation(reduceMotion ? nil : .default) {
                    ProductionDataSync.apply(remote, to: todo)
                    _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
                    rebuildWorkLists()
                }
            } catch {
                guard sessionStore.user?.sessionToken == sessionToken else { return }
                actionErrorMessage = todoActionMessage("Could not update work item.", error: error)
            }
        }
    }

    private func deleteTodos(at offsets: IndexSet) {
        let filtered = currentWorkLists.filtered
        let todosToDelete = offsets.compactMap { index in
            filtered.indices.contains(index) ? filtered[index] : nil
        }
        todosToDelete.forEach(delete)
    }

    private func quickAdd(title: String, requestID: UUID) async throws {
        guard let token = sessionStore.user?.sessionToken else { throw MobileAPIError.invalidResponse }
        let remote = try await MobileAPIClient().createTodo(sessionToken: token, payload: [
            "title": .string(title), "summary": .string(title), "next_action": .string(title),
            "source": .string("mobile"), "status": .string("open"),
            "dedupe_key": .string("mobile:quick-add:\(requestID.uuidString.lowercased())")
        ])
        guard sessionStore.user?.sessionToken == token, let id = UUID(uuidString: remote.id) else {
            throw CancellationError()
        }
        if let existing = todos.first(where: { $0.id == id }) {
            ProductionDataSync.apply(remote, to: existing)
        } else {
            modelContext.insert(ProductionDataSync.todo(from: remote, id: id))
        }
        do { try modelContext.save() } catch {
            modelContext.rollback()
            throw error
        }
        rebuildWorkLists()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func decideTriage(_ todo: TodoItem, action: String) {
        let id = todo.id.uuidString
        guard todo.isInTriage, completion.begin(id) else { return }
        guard let token = sessionStore.user?.sessionToken else {
            actionErrorMessage = "Sign in to save your Triage decisions."
            completion.finish(id)
            return
        }
        actionErrorMessage = nil
        Task { @MainActor in
            defer { completion.finish(id) }
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: token, id: todo.id, action: action)
                guard sessionStore.user?.sessionToken == token, todo.modelContext != nil else { return }
                if action == "done", remote.status == "done" {
                    await completion.confirm(id, reduceMotion: reduceMotion)
                }
                guard sessionStore.user?.sessionToken == token, todo.modelContext != nil else { return }
                try withAnimation(reduceMotion ? nil : .default) {
                    ProductionDataSync.apply(remote, to: todo)
                    try modelContext.save()
                    rebuildWorkLists()
                }
                if action != "done" { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            } catch {
                guard sessionStore.user?.sessionToken == token else { return }
                modelContext.rollback()
                actionErrorMessage = todoActionMessage("Could not save your Triage decision.", error: error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func ignore(_ todo: TodoItem) {
        let id = todo.id.uuidString
        guard todo.isActive, completion.begin(id) else { return }
        actionErrorMessage = nil

        guard let sessionToken = sessionStore.user?.sessionToken else {
            actionErrorMessage = "Sign in to save your Ignore feedback."
            completion.finish(id)
            return
        }

        Task { @MainActor in
            defer { completion.finish(id) }
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "see_less"
                )
                guard sessionStore.user?.sessionToken == sessionToken, todo.modelContext != nil else { return }
                withAnimation(reduceMotion ? nil : .default) {
                    ProductionDataSync.apply(remote, to: todo)
                    _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
                    rebuildWorkLists()
                }
            } catch {
                guard sessionStore.user?.sessionToken == sessionToken else { return }
                actionErrorMessage = todoActionMessage("Could not save Ignore feedback.", error: error)
            }
        }
    }

    private func delete(_ todo: TodoItem) {
        actionErrorMessage = nil

        guard let sessionToken = sessionStore.user?.sessionToken else {
            modelContext.delete(todo)
            _ = saveLocalWorkChange(failureMessage: TodosViewCopy.localDeleteFailedMessage)
            return
        }

        Task { @MainActor in
            do {
                _ = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "dismiss"
                )
                modelContext.delete(todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteDeleteSaveFailedMessage)
            } catch let error as MobileAPIError where error.isNotFound {
                modelContext.delete(todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteDeleteSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage(TodosViewCopy.remoteDismissFailedPrefix, error: error)
            }
        }
    }

    private func snooze(_ todo: TodoItem) {
        actionErrorMessage = nil
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "snooze",
                    snoozedUntil: Calendar.current.date(byAdding: .day, value: 1, to: Date())
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage(TodosViewCopy.remoteSnoozeFailedPrefix, error: error)
            }
        }
    }

    private func markNeedsAction(_ todo: TodoItem) {
        actionErrorMessage = nil
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "important"
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage(TodosViewCopy.remoteImportanceFailedPrefix, error: error)
            }
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requestedFilter = appNavigation.requestedTodoFilter else { return }
        needsInitialView = false
        filter = requestedFilter
        appNavigation.requestedTodoFilter = nil
    }

    private func openRequestedTodoIfNeeded() async {
        guard let id = appNavigation.requestedTodoID else { return }
        needsInitialView = false
        do {
            var descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let todo: TodoItem
            if let saved = try modelContext.fetch(descriptor).first {
                todo = saved
            } else {
                guard let token = sessionStore.user?.sessionToken else { return }
                let remote = try await MobileAPIClient().getTodo(sessionToken: token, id: id)
                todo = TodoItem(id: id, title: remote.title)
                ProductionDataSync.apply(remote, to: todo)
                modelContext.insert(todo)
                try modelContext.save()
            }
            guard appNavigation.requestedTodoID == id else { return }
            linkedTodo = todo
            appNavigation.requestedTodoID = nil
        } catch is CancellationError {
        } catch {
            actionErrorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private func todoActionMessage(_ prefix: String, error: Error) -> String {
        "\(prefix) \(MobileErrorCopy.message(for: error))"
    }

    @discardableResult
    private func saveLocalWorkChange(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            actionErrorMessage = failureMessage
            return false
        }
    }
}

/// Derived list state for the Todos tab, rebuilt only when the todos content,
/// search text, or filter changes instead of on every body pass.
private struct TodoWorkLists {
    let filtered: [TodoItem]
    /// Single-pass per-filter counts for the tab strip, scoped to the search.
    let counts: TodoFilterCounts

    init(todos: [TodoItem], filter: TodoFilter, searchText: String, category: TaskCategory) {
        let todos = todos.filter { category.includes($0.accountCategory) }
        filtered = TodoFiltering.filter(todos, by: filter, searchText: searchText)
        counts = TodoFiltering.counts(in: todos, searchText: searchText)
    }
}

enum TodosViewCopy {
    static let actionWarningTitle = "Work item update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss work item warning"
    static let dismissActionLabel = "Dismiss"
    static let localUpdateFailedMessage = "Could not update the work item on this device. Your work list stayed unchanged."
    static let localDeleteFailedMessage = "Could not dismiss the work item on this device. Your work list stayed unchanged."
    static let remoteDismissFailedPrefix = "Could not dismiss work item."
    static let remoteSnoozeFailedPrefix = "Could not snooze work item."
    static let remoteImportanceFailedPrefix = "Could not move work item to needs action."
    static let remoteUpdateSaveFailedMessage = "Maraithon updated the work item. Refresh work to show the latest state on this device."
    static let remoteDeleteSaveFailedMessage = "Maraithon dismissed the work item. Refresh work to remove it from this device."
    static let restoreFailedMessage = "Could not restore the work item after the update failed. Refresh work to show the latest state."

    static var localSaveFailureLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            dismissActionLabel,
            localUpdateFailedMessage,
            localDeleteFailedMessage,
            remoteDismissFailedPrefix,
            remoteSnoozeFailedPrefix,
            remoteImportanceFailedPrefix,
            remoteUpdateSaveFailedMessage,
            remoteDeleteSaveFailedMessage,
            restoreFailedMessage
        ]
    }
}
