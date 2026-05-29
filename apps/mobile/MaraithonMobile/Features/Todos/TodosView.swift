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
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 3)

                        Text(actionErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Button {
                            self.actionErrorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss work item error")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
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
        try? modelContext.save()

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        Task {
            do {
                let remote = try await MobileAPIClient().updateTodo(
                    sessionToken: sessionToken,
                    id: todo.id,
                    payload: ["status": completed ? "done" : "open"]
                )
                ProductionDataSync.apply(remote, to: todo)
                try? modelContext.save()
            } catch {
                todo.setCompleted(!completed)
                try? modelContext.save()
                actionErrorMessage = todoActionMessage("Could not update work item.", error: error)
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
            try? modelContext.save()
            return
        }

        Task {
            do {
                _ = try await MobileAPIClient().deleteTodo(sessionToken: sessionToken, id: todo.id)
                modelContext.delete(todo)
                try? modelContext.save()
            } catch let error as MobileAPIError where error.isNotFound {
                modelContext.delete(todo)
                try? modelContext.save()
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
}
