import SwiftUI

/// Account-backed work list for the paired Mac. The layout follows the web
/// Todos surface: Todo and next move first, then source, due date, and one
/// quiet completion action per row.
struct TodosView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.todos

        VStack(alignment: .leading, spacing: 0) {
            header(store: store)
            Divider()
            controls(store: store)
            Divider()
            content(store: store)
        }
        .navigationTitle("Todos")
        .task {
            if store.phase == .idle {
                await store.load()
            }
        }
    }

    private func header(store: TodosStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text("Todos")
                    .font(.title2.weight(.semibold))
                Text(TodosCopy.resultCount(store.todos.count, filter: store.filter))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing Todos")
            }
            Button {
                Task { await store.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.medium)
    }

    private func controls(store: TodosStore) -> some View {
        @Bindable var store = store

        return HStack(spacing: Tokens.Spacing.small) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title, next action, or source", text: $store.query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await store.load() }
                    }
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                        Task { await store.load() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.vertical, Tokens.Spacing.xsmall)
            .background(.background, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            Picker("Status", selection: $store.filter) {
                ForEach(TodoListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .onChange(of: store.filter) { _, _ in
                Task { await store.load() }
            }

            Button("Search") {
                Task { await store.load() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.small)
        .background(.bar)
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

                List(store.todos) { todo in
                    TodoRow(
                        todo: todo,
                        isWorking: store.pendingActionIDs.contains(todo.id),
                        action: {
                            Task { await store.performPrimaryAction(on: todo) }
                        }
                    )
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct TodoRow: View {
    let todo: CompanionTodo
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                HStack(spacing: Tokens.Spacing.small) {
                    Text(todo.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if todo.status == "snoozed" {
                        Label("Snoozed", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(StatusTone.attention.color)
                    }
                    if todo.priority >= 75 {
                        Text(todo.priority >= 90 ? "Critical" : "High")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(todo.priority >= 90 ? StatusTone.error.color : StatusTone.attention.color)
                    }
                }

                if let move = todo.recommendedMove {
                    Text("Next: \(move)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let summary = todo.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text(TodosCopy.sourceLabel(todo.source))
                    .font(.callout)
                Text(TodosCopy.attentionLabel(todo.attentionMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)

            Text(TodosCopy.dueLabel(todo.dueDate))
                .font(.caption)
                .foregroundStyle(TodosCopy.dueTone(todo.dueDate).color)
                .frame(width: 96, alignment: .leading)

            Button(actionTitle) {
                action()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWorking || (!todo.canMarkDone && !todo.canReopen))
            .frame(width: 72, alignment: .trailing)
            .overlay {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .opacity(isWorking ? 0.65 : 1)
        }
        .padding(.vertical, Tokens.Spacing.xsmall)
        .accessibilityElement(children: .contain)
    }

    private var actionTitle: String {
        todo.canReopen ? "Reopen" : "Done"
    }
}

enum TodosCopy {
    static func resultCount(_ count: Int, filter: TodoListFilter) -> String {
        let noun = count == 1 ? "work item" : "work items"
        return "\(count) \(filter == .active ? "active" : "completed") \(noun)"
    }

    static func emptyTitle(filter: TodoListFilter, query: String) -> String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching Todos"
        }
        return filter == .active ? "Your open work list is clear" : "No completed work yet"
    }

    static func emptyDescription(filter: TodoListFilter, query: String) -> String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try another title, next action, or source."
        }
        if filter == .active {
            return "Maraithon will surface commitments when the next move is clear."
        }
        return "Completed work will appear here and can be reopened."
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "gmail": return "Gmail"
        case "google_calendar": return "Google Calendar"
        case "imessage": return "iMessage"
        case "browser_history": return "Browser History"
        case "voice_memos": return "Voice Memos"
        case "manual": return "Added by you"
        default:
            return source
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func attentionLabel(_ value: String?) -> String {
        value == "monitor" ? "Watching" : "Needs action"
    }

    static func dueLabel(_ date: Date?) -> String {
        guard let date else { return "No due date" }
        if date < Date() {
            return "Overdue " + date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func dueTone(_ date: Date?) -> StatusTone {
        guard let date else { return .muted }
        return date < Date() ? .error : .muted
    }
}
