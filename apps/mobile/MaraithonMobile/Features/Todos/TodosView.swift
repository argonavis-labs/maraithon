import SwiftData
import SwiftUI

struct TodosView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var todos: [TodoItem]
    @State private var filter: TodoFilter = .open
    @State private var searchText = ""
    @State private var isAddingTodo = false
    @State private var editingTodo: TodoItem?
    @State private var actionErrorMessage: String?
    @State private var refreshErrorMessage: String?
    @State private var isRefreshing = false

    private var filteredTodos: [TodoItem] {
        TodoFiltering.filter(todos, by: filter, searchText: searchText)
    }

    private var filterCounts: TodoFilterCounts {
        TodoFiltering.counts(in: todos, searchText: searchText)
    }

    private var emptyState: TodoEmptyState {
        filter.emptyState(searchText: searchText, hasAnyWork: !todos.isEmpty)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TodoFilterStrip(selection: $filter, counts: filterCounts)

                if let refreshErrorMessage {
                    SyncIssueBanner(
                        message: refreshErrorMessage,
                        retry: { Task { await refreshLatestWork() } },
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

                List {
                    if filteredTodos.isEmpty {
                        ContentUnavailableView(
                            emptyState.title,
                            systemImage: emptyState.systemImage,
                            description: Text(emptyState.description)
                        )
                    } else {
                        ForEach(filteredTodos) { todo in
                            TodoRow(todo: todo) {
                                toggle(todo)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingTodo = todo
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    toggle(todo)
                                } label: {
                                    Label(
                                        todo.isCompleted ? "Reopen" : "Complete",
                                        systemImage: todo.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle"
                                    )
                                }
                                .tint(todo.isCompleted ? .orange : .green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(todo)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    editingTodo = todo
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                        .onDelete(perform: deleteTodos)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(filter.navigationTitle)
            .searchable(text: $searchText, prompt: "Search open work")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingTodo = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add work item")
                }
            }
            .sheet(isPresented: $isAddingTodo) {
                TodoEditorView()
            }
            .sheet(item: $editingTodo) { todo in
                TodoEditorView(todo: todo)
            }
            .task {
                await refreshLatestWork()
            }
            .onAppear(perform: applyRequestedFilterIfNeeded)
            .onChange(of: appNavigation.requestedTodoFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
        }
    }

    private func refreshLatestWork() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await ProductionDataSync.refreshTodos(
                sessionStore: sessionStore,
                modelContext: modelContext
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh work. \(MobileErrorCopy.message(for: error))"
        }
    }

    private func toggle(_ todo: TodoItem) {
        let completed = !todo.isCompleted
        actionErrorMessage = nil
        todo.setCompleted(completed)
        guard saveLocalWorkChange(failureMessage: TodosViewCopy.localUpdateFailedMessage) else {
            return
        }

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().updateTodo(
                    sessionToken: sessionToken,
                    id: todo.id,
                    payload: ["status": completed ? "done" : "open"]
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
            } catch {
                todo.setCompleted(!completed)
                if saveLocalWorkChange(failureMessage: TodosViewCopy.restoreFailedMessage) {
                    actionErrorMessage = todoActionMessage("Could not update work item.", error: error)
                }
            }
        }
    }

    private func deleteTodos(at offsets: IndexSet) {
        let todosToDelete = offsets.map { filteredTodos[$0] }
        todosToDelete.forEach(delete)
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
                _ = try await MobileAPIClient().deleteTodo(sessionToken: sessionToken, id: todo.id)
                modelContext.delete(todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteDeleteSaveFailedMessage)
            } catch let error as MobileAPIError where error.isNotFound {
                modelContext.delete(todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteDeleteSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage("Could not delete work item.", error: error)
            }
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requestedFilter = appNavigation.requestedTodoFilter else { return }
        filter = requestedFilter
        appNavigation.requestedTodoFilter = nil
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

enum TodosViewCopy {
    static let actionWarningTitle = "Work item update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss work item warning"
    static let localUpdateFailedMessage = "Could not update the work item on this device. Your work list stayed unchanged."
    static let localDeleteFailedMessage = "Could not delete the work item on this device. Your work list stayed unchanged."
    static let remoteUpdateSaveFailedMessage = "Maraithon updated the work item. Refresh work to show the latest state on this device."
    static let remoteDeleteSaveFailedMessage = "Maraithon deleted the work item. Refresh work to remove it from this device."
    static let restoreFailedMessage = "Could not restore the work item after the update failed. Refresh work to show the latest state."

    static var localSaveFailureLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            localUpdateFailedMessage,
            localDeleteFailedMessage,
            remoteUpdateSaveFailedMessage,
            remoteDeleteSaveFailedMessage,
            restoreFailedMessage
        ]
    }
}
