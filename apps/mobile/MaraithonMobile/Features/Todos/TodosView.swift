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

    private var filteredTodos: [TodoItem] {
        TodoFiltering.filter(todos, by: filter, searchText: searchText)
    }

    private var filterCounts: TodoFilterCounts {
        TodoFiltering.counts(in: todos, searchText: searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TodoFilterStrip(selection: $filter, counts: filterCounts)

                List {
                    if filteredTodos.isEmpty {
                        ContentUnavailableView(
                            "No Todos",
                            systemImage: "checklist",
                            description: Text("Add a follow-up or switch filters.")
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
            .navigationTitle("Todos")
            .searchable(text: $searchText, prompt: "Search todos")
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
                    .accessibilityLabel("Add Todo")
                }
            }
            .sheet(isPresented: $isAddingTodo) {
                TodoEditorView()
            }
            .sheet(item: $editingTodo) { todo in
                TodoEditorView(todo: todo)
            }
            .task {
                try? await ProductionDataSync.refreshTodos(
                    sessionStore: sessionStore,
                    modelContext: modelContext
                )
            }
            .onAppear(perform: applyRequestedFilterIfNeeded)
            .onChange(of: appNavigation.requestedTodoFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
        }
    }

    private func toggle(_ todo: TodoItem) {
        let completed = !todo.isCompleted
        todo.setCompleted(completed)
        try? modelContext.save()

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        Task {
            let remote = try? await MobileAPIClient().updateTodo(
                sessionToken: sessionToken,
                id: todo.id,
                payload: ["status": completed ? "done" : "open"]
            )
            if let remote {
                ProductionDataSync.apply(remote, to: todo)
                try? modelContext.save()
            }
        }
    }

    private func deleteTodos(at offsets: IndexSet) {
        for offset in offsets {
            delete(filteredTodos[offset], shouldSave: false)
        }
        try? modelContext.save()
    }

    private func delete(_ todo: TodoItem, shouldSave: Bool = true) {
        modelContext.delete(todo)
        if shouldSave {
            try? modelContext.save()
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requestedFilter = appNavigation.requestedTodoFilter else { return }
        filter = requestedFilter
        appNavigation.requestedTodoFilter = nil
    }
}
