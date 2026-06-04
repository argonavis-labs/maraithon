import SwiftData
import SwiftUI

struct TodoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    let todo: TodoItem

    @State private var chatThread: ChatThread?
    @State private var isLoadingThread = false
    @State private var loadErrorMessage: String?
    @State private var isEditingTodo = false

    private let chatSyncService = ChatSyncService()

    var body: some View {
        Group {
            if let chatThread {
                ChatDetailView(
                    thread: chatThread,
                    contextHeader: todoContextHeader,
                    quickPrompts: todoQuickPrompts
                )
            } else {
                loadingView
            }
        }
        .navigationTitle(TodoDetailCopy.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditingTodo = true
                } label: {
                    Label(TodoDetailCopy.editButtonTitle, systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $isEditingTodo) {
            TodoEditorView(todo: todo)
        }
        .task(id: todo.id) {
            await loadThreadIfNeeded()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()

            if isLoadingThread {
                ProgressView(TodoDetailCopy.loadingTitle)
            } else if let loadErrorMessage {
                ContentUnavailableView {
                    Label(TodoDetailCopy.loadingFailedTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadErrorMessage)
                } actions: {
                    Button(TodoDetailCopy.retryButtonTitle) {
                        Task { await loadThread() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView(TodoDetailCopy.loadingTitle)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var todoContextHeader: ChatContextHeader {
        let context = TodoDecisionContext(todo: todo)
        var items: [ChatContextHeader.Item] = []

        appendItem("context", "Context", context.contextSummary ?? context.notesContext, "text.alignleft", to: &items)
        appendItem("decision", "Decision", context.decisionPrompt, "target", to: &items)
        appendItem("why-now", "Why now", context.whyNow, "clock.badge.exclamationmark", to: &items)
        appendItem("source", "Source", context.sourceContext, "tray.full", to: &items)
        appendItem("next", "Next move", context.rowMove, "arrow.turn.down.right", to: &items)
        appendItem("draft", "Draft", context.draftPreview, "square.and.pencil", to: &items)
        appendItem("evidence", "Evidence", context.evidence, "quote.bubble", to: &items)

        return ChatContextHeader(
            title: todo.title,
            subtitle: todoSubtitle,
            systemImage: todo.isCompleted ? "checkmark.circle.fill" : "circle.dotted",
            status: ChatContextHeader.Status(
                title: todo.isCompleted ? "Done" : "Open",
                tint: todo.isCompleted ? .green : .blue
            ),
            items: items
        )
    }

    private var todoSubtitle: String? {
        var parts = [todo.priority.title]

        if let dueDate = todo.dueDate {
            parts.append(dueDate.formatted(AppFormatters.shortDate))
        }

        if let contactName = cleanedText(todo.contact?.name) {
            parts.append(contactName)
        }

        return parts.joined(separator: " - ")
    }

    private var todoQuickPrompts: [ChiefOfStaffPrompt] {
        [
            ChiefOfStaffPrompt(
                id: "todo-next-move",
                title: "Next move",
                subtitle: "Work from the selected item.",
                message: "Help me handle this selected work item. Start with the context, then give me the smallest useful next move.",
                systemImage: "arrow.turn.down.right",
                tint: .blue
            ),
            ChiefOfStaffPrompt(
                id: "todo-draft-reply",
                title: "Draft reply",
                subtitle: "Prepare the message.",
                message: "Draft the best reply or outbound message for this selected work item. If it is ready to send by email or Slack, prepare the action for my approval.",
                systemImage: "square.and.pencil",
                tint: .indigo
            ),
            ChiefOfStaffPrompt(
                id: "todo-take-action",
                title: "Take action",
                subtitle: "Draft and prepare.",
                message: "Help me take action on this selected work item. Draft the email or Slack message and prepare it for my approval if you have enough context.",
                systemImage: "paperplane",
                tint: .purple
            ),
            ChiefOfStaffPrompt(
                id: "todo-mark-done",
                title: "Mark done",
                subtitle: "Complete the selected item.",
                message: "This selected work item is done. Mark it complete.",
                systemImage: "checkmark.circle",
                tint: .green
            )
        ]
    }

    private func loadThreadIfNeeded() async {
        guard chatThread == nil else { return }
        await loadThread()
    }

    private func loadThread() async {
        guard !isLoadingThread else { return }
        isLoadingThread = true
        defer { isLoadingThread = false }

        do {
            chatThread = try await chatSyncService.openTodoThread(
                for: todo,
                modelContext: modelContext,
                sessionStore: sessionStore
            )
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private func appendItem(
        _ id: String,
        _ title: String,
        _ body: String?,
        _ systemImage: String,
        to items: inout [ChatContextHeader.Item]
    ) {
        guard let body = cleanedText(body) else { return }
        items.append(ChatContextHeader.Item(id: id, title: title, body: body, systemImage: systemImage))
    }

    private func cleanedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TodoDetailCopy {
    static let navigationTitle = "Work"
    static let editButtonTitle = "Edit"
    static let loadingTitle = "Opening work chat"
    static let loadingFailedTitle = "Could not open work chat"
    static let retryButtonTitle = "Try again"
}
