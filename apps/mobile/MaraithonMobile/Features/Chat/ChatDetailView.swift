import SwiftData
import SwiftUI
import UIKit

struct ChatDetailView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var thread: ChatThread
    var focusComposerOnAppear = false
    var initialPrompt: String?
    var autoSendInitialPrompt = false
    var onInitialPromptConsumed: () -> Void = {}
    var contextHeader: ChatContextHeader?
    var sourceAction: TodoSourceAction?
    var sourceActionSend: ((String, String?) async throws -> Void)?
    var quickPrompts: [ChiefOfStaffPrompt]
    var workspaceHeader: ((@escaping (String) -> Void, Bool) -> AnyView)?
    @Binding var requestedPrompt: String?
    @SceneStorage private var draft: String
    @State private var streamPreview: String?
    @State private var connectionNotice: String?
    @State private var errorMessage: String?
    @State private var lastFailedMessage: String?
    @State private var isSending = false
    @State private var isRenamingThread = false
    @State private var draftThreadTitle = ""
    @State private var didConsumeInitialPrompt = false
    @State private var sendTask: Task<Void, Never>?
    @State private var renameTask: Task<Void, Never>?
    @State private var deleteTask: Task<Void, Never>?
    @State private var visibleMessageLimit = 60
    @State private var timelineRows: [ChatTimelineRow]
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
        sourceAction: TodoSourceAction? = nil,
        sourceActionSend: ((String, String?) async throws -> Void)? = nil,
        quickPrompts: [ChiefOfStaffPrompt] = ChiefOfStaffPrompt.chat,
        requestedPrompt: Binding<String?> = .constant(nil),
        workspaceHeader: ((@escaping (String) -> Void, Bool) -> AnyView)? = nil
    ) {
        self.thread = thread
        self.focusComposerOnAppear = focusComposerOnAppear
        self.initialPrompt = initialPrompt
        self.autoSendInitialPrompt = autoSendInitialPrompt
        self.onInitialPromptConsumed = onInitialPromptConsumed
        self.contextHeader = contextHeader
        self.sourceAction = sourceAction
        self.sourceActionSend = sourceActionSend
        self.quickPrompts = quickPrompts
        self.workspaceHeader = workspaceHeader
        _requestedPrompt = requestedPrompt
        _draft = SceneStorage(wrappedValue: "", "chat.composer.\(thread.id.uuidString)")
        // Seed the timeline so the first frame renders without an empty flash;
        // it is kept fresh via onChange(of: thread.messages.count). The body
        // re-runs on every draft keystroke, so the sort must not live in a
        // computed property.
        _timelineRows = State(initialValue: ChatMessageTimeline.rows(for: thread.messages))
    }

    private func rebuildTimelineRows() {
        timelineRows = ChatMessageTimeline.rows(for: thread.messages)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    // Measure variable-height draft cards before jumping to a
                    // new turn. Lazy height estimation can loop during a long
                    // programmatic scroll on iOS 26; bound the initial history.
                    VStack(spacing: 0) {
                        if let workspaceHeader {
                            workspaceHeader(send, isComposerDisabled)
                                .padding(.bottom, 16)
                        }

                        if let contextHeader {
                            ChatContextHeaderView(header: contextHeader)
                                .padding(.bottom, 12)
                        }

                        if let sourceAction {
                            SourceActionCardView(action: sourceAction, onSend: sourceActionSend)
                                .padding(.bottom, 12)
                        }

                        if timelineRows.isEmpty {
                            emptyConversation
                                .padding(.top, workspaceHeader == nil && contextHeader == nil ? 80 : 16)
                        } else {
                            if timelineRows.count > visibleMessageLimit {
                                Button("Show earlier messages") { visibleMessageLimit += 60 }
                                    .font(.subheadline).padding(.vertical, 12)
                            }
                            ForEach(timelineRows.suffix(visibleMessageLimit)) { row in
                                if row.layout.showsDateHeader {
                                    ChatDateHeader(date: row.message.sentAt)
                                        .padding(.top, 8)
                                        .padding(.bottom, 8)
                                }

                                MessageBubble(
                                    message: row.message,
                                    startsGroup: row.layout.startsGroup,
                                    endsGroup: row.layout.endsGroup,
                                    actionHandler: decide,
                                    prepareHandler: send,
                                    actionsDisabled: isComposerDisabled
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
                .defaultScrollAnchor(workspaceHeader == nil ? .bottom : .top)
                .onChange(of: thread.messages.count) { _, _ in
                    rebuildTimelineRows()
                    scrollToBottom(proxy)
                }
                .onChange(of: thread.pendingRunID) { _, runID in
                    if runID != nil { scrollToBottom(proxy) }
                }
                .onAppear {
                    if workspaceHeader == nil { scrollToBottom(proxy, animated: false) }
                    if focusComposerOnAppear || (workspaceHeader == nil && thread.messages.isEmpty) {
                        isComposerFocused = true
                    }
                    consumeInitialPromptIfNeeded()
                }
            }
        }
        .onChange(of: requestedPrompt) { _, _ in consumeRequestedPrompt() }
        .onChange(of: isComposerDisabled) { _, disabled in
            if !disabled { consumeRequestedPrompt() }
        }
        .task(id: "\(thread.remoteID?.uuidString ?? "local")-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await refreshConversation()
            await chatSyncService.observeThread(thread, modelContext: modelContext, sessionStore: sessionStore,
                onPreview: { streamPreview = $0 },
                onFailure: { errorMessage = $0 }) { notice in
                connectionNotice = notice
                rebuildTimelineRows()
            }
        }
        .onDisappear {
            sendTask?.cancel()
            renameTask?.cancel()
            deleteTask?.cancel()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if workspaceHeader == nil && shouldShowQuickPrompts {
                    quickPromptBar
                }
                if let errorMessage {
                    errorBanner(errorMessage, actionTitle: errorActionTitle)
                } else if let connectionNotice {
                    Text(connectionNotice).font(.caption).foregroundStyle(.secondary)
                }
                composer
            }
            .background(.bar)
        }
        .modifier(ChatNavigationTitle(title: workspaceHeader == nil ? thread.title : nil))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if workspaceHeader == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { beginRenameThread() } label: {
                            Label(ChatDetailCopy.renameMenuTitle, systemImage: "pencil")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(ChatDetailCopy.threadOptionsAccessibilityLabel)
                }
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

            TextField(workspaceHeader == nil ? ChatDetailCopy.messageFieldPlaceholder : "Ask about this todo…", text: $draft, axis: .vertical)
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

            VStack(alignment: .leading, spacing: 8) {
                ChatPendingWorkSummary(summary: thread.pendingWorkSummary)
                if let streamPreview, !streamPreview.isEmpty {
                    Text(streamPreview).font(.body).textSelection(.enabled)
                }
            }
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
        guard !body.isEmpty, !isComposerDisabled else { return }

        if text == draft {
            draft = ""
        }

        errorMessage = nil
        lastFailedMessage = nil
        isComposerFocused = false
        isSending = true
        sendTask?.cancel()
        sendTask = Task {
            defer { isSending = false }

            do {
                try await chatSyncService.send(
                    body,
                    in: thread,
                    modelContext: modelContext,
                    sessionStore: sessionStore
                )
            } catch is CancellationError {
                return
            } catch {
                lastFailedMessage = body
                errorMessage = MobileErrorCopy.message(for: error)
                return
            }

            await refreshConversation()
        }
    }

    private func decide(_ action: ChatMessageAction) {
        guard action.decision != nil, !isComposerDisabled else { return }
        isSending = true

        errorMessage = nil
        sendTask?.cancel()
        sendTask = Task {
            defer { isSending = false }
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

    private func refreshConversation() async {
        do {
            try await chatSyncService.refreshThread(
                thread,
                modelContext: modelContext,
                sessionStore: sessionStore
            )
            // A process killed before receiving the response leaves an
            // optimistic row in "sending". Reconcile the server first, then
            // expose a retry using that same persisted client message ID.
            if !isSending {
                for message in thread.messages where message.role == .user &&
                    message.remoteID == nil && message.deliveryState == .sending {
                    message.deliveryState = .failed
                }
                try modelContext.save()
            }
            let failed = thread.messages
                .filter { $0.role == .user && $0.deliveryState == .failed && $0.remoteID == nil }
                .max { $0.sentAt < $1.sentAt }
            lastFailedMessage = failed?.body
            errorMessage = failed == nil ? nil : "Your message was not confirmed. You can safely retry it."
            // A merge can update existing messages without changing the count.
            rebuildTimelineRows()
        } catch is CancellationError {
            return
        } catch ChatSyncError.missingSession {
            return
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
            return
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

    private func consumeRequestedPrompt() {
        guard let prompt = requestedPrompt, !isComposerDisabled else { return }
        requestedPrompt = nil
        send(prompt)
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
                await refreshConversation()
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
            // Solid fill instead of .thinMaterial: material blur is expensive
            // inside scrolling rows.
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

private struct ChatNavigationTitle: ViewModifier {
    let title: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let title { content.navigationTitle(title) } else { content }
    }
}
