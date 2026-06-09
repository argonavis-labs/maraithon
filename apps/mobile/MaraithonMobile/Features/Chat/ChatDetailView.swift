import SwiftData
import SwiftUI
import UIKit

struct ChatDetailView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @Bindable var thread: ChatThread
    var focusComposerOnAppear = false
    var initialPrompt: String?
    var autoSendInitialPrompt = false
    var onInitialPromptConsumed: () -> Void = {}
    var contextHeader: ChatContextHeader?
    var quickPrompts: [ChiefOfStaffPrompt]
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var lastFailedMessage: String?
    @State private var isSending = false
    @State private var isRenamingThread = false
    @State private var draftThreadTitle = ""
    @State private var didConsumeInitialPrompt = false
    @State private var sendTask: Task<Void, Never>?
    @State private var renameTask: Task<Void, Never>?
    @State private var deleteTask: Task<Void, Never>?
    @FocusState private var isComposerFocused: Bool

    private let chatSyncService = ChatSyncService()
    private let bottomAnchorID = "chat-bottom-anchor"

    init(
        thread: ChatThread,
        focusComposerOnAppear: Bool = false,
        initialPrompt: String? = nil,
        autoSendInitialPrompt: Bool = false,
        onInitialPromptConsumed: @escaping () -> Void = {},
        contextHeader: ChatContextHeader? = nil,
        quickPrompts: [ChiefOfStaffPrompt] = ChiefOfStaffPrompt.chat
    ) {
        self.thread = thread
        self.focusComposerOnAppear = focusComposerOnAppear
        self.initialPrompt = initialPrompt
        self.autoSendInitialPrompt = autoSendInitialPrompt
        self.onInitialPromptConsumed = onInitialPromptConsumed
        self.contextHeader = contextHeader
        self.quickPrompts = quickPrompts
    }

    private var timelineRows: [ChatTimelineRow] {
        ChatMessageTimeline.rows(for: thread.messages)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let contextHeader {
                            ChatContextHeaderView(header: contextHeader)
                                .padding(.bottom, 12)
                        }

                        if timelineRows.isEmpty {
                            emptyConversation
                                .padding(.top, contextHeader == nil ? 80 : 24)
                        } else {
                            ForEach(timelineRows) { row in
                                if row.layout.showsDateHeader {
                                    ChatDateHeader(date: row.message.sentAt)
                                        .padding(.top, 8)
                                        .padding(.bottom, 8)
                                }

                                MessageBubble(
                                    message: row.message,
                                    startsGroup: row.layout.startsGroup,
                                    endsGroup: row.layout.endsGroup,
                                    actionHandler: decide
                                )
                                .id(row.id)
                                .padding(.top, row.layout.startsGroup ? 8 : 2)
                                .contextMenu {
                                    Button {
                                        copy(row.message)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }

                                    Button(role: .destructive) {
                                        delete(row.message)
                                    } label: {
                                        Label(ChatDetailCopy.deleteMessageTitle, systemImage: "trash")
                                    }
                                }
                            }
                        }

                        if thread.pendingRunID != nil {
                            assistantPendingRow
                                .padding(.top, 8)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                    if focusComposerOnAppear || thread.messages.isEmpty {
                        isComposerFocused = true
                    }
                    consumeInitialPromptIfNeeded()
                }
            }
        }
        .task {
            await refreshAndPollIfNeeded()
        }
        .onDisappear {
            sendTask?.cancel()
            renameTask?.cancel()
            deleteTask?.cancel()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if shouldShowQuickPrompts {
                    quickPromptBar
                }
                if let errorMessage {
                    errorBanner(errorMessage, actionTitle: errorActionTitle)
                }
                composer
            }
            .background(.bar)
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        beginRenameThread()
                    } label: {
                        Label(ChatDetailCopy.renameMenuTitle, systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(ChatDetailCopy.threadOptionsAccessibilityLabel)
            }
        }
        .alert(ChatDetailCopy.renameAlertTitle, isPresented: $isRenamingThread) {
            TextField(ChatDetailCopy.renameFieldPlaceholder, text: $draftThreadTitle)
            Button("Save") {
                renameThread()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ChatDetailCopy.renameAlertMessage)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Section("Prompts") {
                    ForEach(quickPrompts) { prompt in
                        Button {
                            send(prompt.message)
                        } label: {
                            Label(prompt.title, systemImage: prompt.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .appInteractiveGlassCircle()
            }
            .accessibilityLabel(ChatDetailCopy.messageOptionsAccessibilityLabel)

            TextField(ChatDetailCopy.messageFieldPlaceholder, text: $draft, axis: .vertical)
                .focused($isComposerFocused)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(isComposerDisabled)
                .accessibilityIdentifier("chat-message-field")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .appProminentGlassCircleActionStyle()
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isComposerDisabled)
            .accessibilityLabel(ChatDetailCopy.sendMessageAccessibilityLabel)
            .accessibilityIdentifier("chat-send-button")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var shouldShowQuickPrompts: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isComposerDisabled
    }

    private var isComposerDisabled: Bool {
        isSending || thread.pendingRunID != nil || sessionStore.user?.sessionToken == nil
    }

    private var errorActionTitle: String {
        ChatDetailErrorCopy.recoveryActionTitle(canRetrySend: lastFailedMessage != nil)
    }

    private var quickPromptBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(quickPrompts) { prompt in
                    Button {
                        send(prompt.message)
                    } label: {
                        Label(prompt.title, systemImage: prompt.systemImage)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .appGlassActionStyle()
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 8)
    }

    private var emptyConversation: some View {
        ContentUnavailableView(
            ChatDetailCopy.emptyTitle,
            systemImage: "bubble.left.and.bubble.right",
            description: Text(ChatDetailCopy.emptyDescription)
        )
    }

    private var assistantPendingRow: some View {
        HStack(alignment: .bottom, spacing: 7) {
            ChatAvatar(title: "Maraithon", systemImage: "sparkles", size: 28, tint: .accentColor)

            ChatPendingWorkSummary(summary: thread.pendingWorkSummary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityIdentifier("chat-assistant-pending")

            Spacer(minLength: 56)
        }
    }

    private func errorBanner(_ message: String, actionTitle: String) -> some View {
        HStack(spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(actionTitle) {
                recoverAfterError()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func send() {
        send(draft)
    }

    private func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        if text == draft {
            draft = ""
        }

        errorMessage = nil
        lastFailedMessage = nil
        isComposerFocused = true
        sendTask?.cancel()
        sendTask = Task {
            isSending = true
            defer { isSending = false }

            do {
                try await chatSyncService.send(
                    body,
                    in: thread,
                    modelContext: modelContext,
                    sessionStore: sessionStore
                )
                try await chatSyncService.pollPendingRun(
                    in: thread,
                    modelContext: modelContext,
                    sessionStore: sessionStore
                )
            } catch is CancellationError {
            } catch {
                lastFailedMessage = body
                errorMessage = MobileErrorCopy.message(for: error)
            }
        }
    }

    private func decide(_ action: ChatMessageAction) {
        guard action.decision != nil else { return }

        errorMessage = nil
        sendTask?.cancel()
        sendTask = Task {
            do {
                try await chatSyncService.decidePreparedAction(
                    action,
                    in: thread,
                    modelContext: modelContext,
                    sessionStore: sessionStore
                )
            } catch is CancellationError {
            } catch {
                errorMessage = MobileErrorCopy.message(for: error)
            }
        }
    }

    private func beginRenameThread() {
        draftThreadTitle = thread.title
        isRenamingThread = true
    }

    private func renameThread() {
        let title = draftThreadTitle
        errorMessage = nil
        renameTask?.cancel()
        renameTask = Task {
            do {
                try await chatSyncService.renameThread(
                    thread,
                    title: title,
                    modelContext: modelContext,
                    sessionStore: sessionStore
                )
            } catch is CancellationError {
            } catch {
                errorMessage = MobileErrorCopy.message(for: error)
            }
        }
    }

    private func refreshAndPollIfNeeded() async {
        do {
            try await chatSyncService.refreshThread(
                thread,
                modelContext: modelContext,
                sessionStore: sessionStore
            )
            try await chatSyncService.pollPendingRun(
                in: thread,
                modelContext: modelContext,
                sessionStore: sessionStore
            )
            errorMessage = nil
            lastFailedMessage = nil
        } catch is CancellationError {
        } catch ChatSyncError.missingSession {
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private func delete(_ message: ChatMessage) {
        errorMessage = nil
        deleteTask?.cancel()
        deleteTask = Task {
            do {
                try await chatSyncService.deleteMessage(
                    message,
                    from: thread,
                    modelContext: modelContext,
                    sessionStore: sessionStore
                )
            } catch is CancellationError {
            } catch {
                errorMessage = MobileErrorCopy.message(for: error)
            }
        }
    }

    private func copy(_ message: ChatMessage) {
        UIPasteboard.general.string = message.body
    }

    private func consumeInitialPromptIfNeeded() {
        guard !didConsumeInitialPrompt,
              let initialPrompt,
              thread.messages.isEmpty else {
            return
        }

        didConsumeInitialPrompt = true
        onInitialPromptConsumed()

        if autoSendInitialPrompt {
            send(initialPrompt)
        } else {
            draft = initialPrompt
            isComposerFocused = true
        }
    }

    private func recoverAfterError() {
        if let lastFailedMessage {
            send(lastFailedMessage)
        } else {
            Task {
                await refreshAndPollIfNeeded()
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.snappy) {
                action()
            }
        } else {
            action()
        }
    }
}

enum ChatDetailErrorCopy {
    static func recoveryActionTitle(canRetrySend: Bool) -> String {
        canRetrySend ? "Send again" : "Refresh chat"
    }
}

enum ChatDetailCopy {
    static let deleteMessageTitle = "Delete message"
    static let renameMenuTitle = "Rename"
    static let threadOptionsAccessibilityLabel = "Thread options"
    static let renameAlertTitle = "Rename chat"
    static let renameFieldPlaceholder = "Chat name"
    static let renameAlertMessage = "Use a short name that makes this conversation easy to find later."
    static let messageOptionsAccessibilityLabel = "Message options"
    static let messageFieldPlaceholder = "Message"
    static let sendMessageAccessibilityLabel = "Send message"
    static let emptyTitle = "Ask Maraithon"
    static let emptyDescription = "Plan the day, draft a follow-up, update a relationship, or capture a work item."

    static var visibleLabels: [String] {
        [
            deleteMessageTitle,
            renameMenuTitle,
            threadOptionsAccessibilityLabel,
            renameAlertTitle,
            renameFieldPlaceholder,
            renameAlertMessage,
            messageOptionsAccessibilityLabel,
            messageFieldPlaceholder,
            sendMessageAccessibilityLabel,
            emptyTitle,
            emptyDescription
        ]
    }
}

struct ChatContextHeader {
    struct Status {
        let title: String
        let tint: Color
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let body: String
        let systemImage: String
    }

    let title: String
    let subtitle: String?
    let systemImage: String
    let status: Status?
    let items: [Item]
}

private struct ChatDateHeader: View {
    let date: Date

    var body: some View {
        Text(AppFormatters.chatDayString(for: date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }
}
