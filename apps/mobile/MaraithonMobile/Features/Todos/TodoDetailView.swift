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
                    sourceAction: todo.sourceAction,
                    quickPrompts: todoQuickPrompts
                )
            } else {
                progressiveDetailView
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

    private var progressiveDetailView: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ChatContextHeaderView(header: todoContextHeader)

                    if let sourceAction = todo.sourceAction {
                        SourceActionCardView(action: sourceAction)
                    }

                    chatLoadingCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .accessibilityIdentifier("todo-progressive-detail")
    }

    @ViewBuilder
    private var chatLoadingCard: some View {
        if let loadErrorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label(TodoDetailCopy.loadingFailedTitle, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)

                Text(loadErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(TodoDetailCopy.retryButtonTitle) {
                    Task { await loadThread() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(isLoadingThread ? TodoDetailCopy.loadingDetailsTitle : TodoDetailCopy.loadingQueuedTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var todoContextHeader: ChatContextHeader {
        let context = TodoDecisionContext(todo: todo)
        var items: [ChatContextHeader.Item] = []

        appendItem("context", "Context", context.contextSummary ?? context.notesContext, "text.alignleft", to: &items)
        appendItem("decision", "Decision", context.decisionPrompt, "target", to: &items)
        appendItem("why-now", "Why now", context.whyNow, "clock.badge.exclamationmark", to: &items)
        appendItem("source", "Source", context.sourceContext, "tray.full", to: &items)
        appendItem("next", "Next move", context.rowMove, "arrow.turn.down.right", to: &items)

        // The interactive source action card owns the draft when present.
        if todo.sourceAction?.hasDraft != true {
            appendItem("draft", "Draft", context.draftPreview, "square.and.pencil", to: &items)
        }

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
                message: "Create the real connected draft for this selected work item. If it is Gmail or email, save a Gmail draft and prepare the saved draft for my approval. If it is Slack, prepare the Slack message for my approval. If it is iMessage or Messages, use the drafted wording and open Messages with the recipient and body instead of pretending to send from the server.",
                systemImage: "square.and.pencil",
                tint: .indigo
            ),
            ChiefOfStaffPrompt(
                id: "todo-take-action",
                title: "Take action",
                subtitle: "Draft and prepare.",
                message: "Help me take action on this selected work item. Create the real provider draft or prepared send action: saved Gmail draft for email, Slack prepared message for Slack, or Messages opener for iMessage. If you have enough context, make it ready for me to send.",
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
    static let loadingDetailsTitle = "Loading details"
    static let loadingQueuedTitle = "Preparing details"
    static let loadingFailedTitle = "Could not open work chat"
    static let retryButtonTitle = "Try again"
}
