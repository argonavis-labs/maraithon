import SwiftData
import SwiftUI

struct ChatThreadsView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var pendingPromptByThreadID: [UUID: PendingChatPrompt] = [:]

    private let chatSyncService = ChatSyncService()

    private var standaloneThreads: [ChatThread] {
        threads.filter(\.isStandaloneChat)
    }

    private var filteredThreads: [ChatThread] {
        ChatThreadFiltering.filter(standaloneThreads, searchText: searchText)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                pageHeader
                    .listRowInsets(EdgeInsets(
                        top: Runner.Spacing.small,
                        leading: Runner.Layout.pageInset,
                        bottom: Runner.Spacing.small,
                        trailing: Runner.Layout.pageInset
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Runner.Palette.background)

                if let errorMessage {
                    SyncIssueBanner(
                        title: ChatThreadsCopy.refreshWarningTitle,
                        message: errorMessage,
                        buttonTitle: ChatThreadsCopy.refreshButtonTitle,
                        retry: { Task { await refreshThreads() } },
                        dismiss: { self.errorMessage = nil }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Runner.Palette.background)
                }

                if let actionErrorMessage {
                    SyncIssueBanner(
                        title: ChatThreadsCopy.actionWarningTitle,
                        message: actionErrorMessage,
                        buttonTitle: nil,
                        retry: nil,
                        dismissAccessibilityLabel: ChatThreadsCopy.dismissActionWarningAccessibilityLabel,
                        dismiss: { self.actionErrorMessage = nil }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Runner.Palette.background)
                }

                if filteredThreads.isEmpty {
                    Group {
                        if standaloneThreads.isEmpty {
                            emptyChatState
                        } else {
                            RunnerEmptyState(
                                title: ChatThreadsCopy.noMatchingChatsTitle,
                                description: ChatThreadsCopy.noMatchingChatsDescription,
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Runner.Palette.background)
                } else {
                    ForEach(filteredThreads) { thread in
                        NavigationLink(value: thread.id) {
                            ChatThreadRow(thread: thread)
                        }
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: Runner.Layout.pageInset,
                            bottom: 0,
                            trailing: Runner.Layout.pageInset
                        ))
                        .listRowBackground(Runner.Palette.background)
                        .listRowSeparatorTint(Runner.Palette.border)
                    }
                    .onDelete(perform: deleteThreads)
                }
            }
            .listStyle(.plain)
            .runnerPage()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await refreshThreads(force: true)
            }
            .task {
                await refreshThreads()
            }
            .onAppear(perform: consumeRequestedPromptIfNeeded)
            .onChange(of: appNavigation.requestedChatPrompt) { _, _ in
                consumeRequestedPromptIfNeeded()
            }
            .task(id: appNavigation.requestedChatThreadID) {
                await consumeRequestedThreadIfNeeded()
            }
            .navigationDestination(for: UUID.self) { threadID in
                if let thread = standaloneThreads.first(where: { $0.id == threadID }) {
                    let pendingPrompt = pendingPromptByThreadID[threadID]
                    ChatDetailView(
                        thread: thread,
                        focusComposerOnAppear: thread.messages.isEmpty && pendingPrompt == nil,
                        initialPrompt: pendingPrompt?.message,
                        autoSendInitialPrompt: pendingPrompt?.shouldAutoSend ?? false
                    ) {
                        pendingPromptByThreadID[threadID] = nil
                    }
                } else {
                    VStack {
                        RunnerEmptyState(
                            title: ChatThreadsCopy.deletedChatTitle,
                            description: ChatThreadsCopy.deletedChatDescription,
                            systemImage: "bubble.left.and.exclamationmark.bubble.right"
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.top, Runner.Spacing.xlarge)
                    .runnerPage()
                }
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            RunnerPageHeader(
                eyebrow: "Your workspace",
                title: "Chat",
                count: standaloneThreads.count,
                subtitle: "Ask your chief of staff anything about your work."
            ) {
                HStack(spacing: Runner.Spacing.small) {
                    AccountMenuButton()
                    Button {
                        createThread()
                    } label: {
                        HStack(spacing: Runner.Spacing.compact) {
                            Image(systemName: "square.and.pencil")
                                .accessibilityHidden(true)
                            Text(ChatThreadsCopy.newChatButtonTitle)
                        }
                    }
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .accessibilityLabel(ChatThreadsCopy.newChatButtonTitle)
                }
            }

            RunnerSearchField(placeholder: "Search chats", text: $searchText)
        }
    }

    private func refreshThreads(force: Bool = false) async {
        do {
            try await chatSyncService.refreshThreads(
                modelContext: modelContext,
                sessionStore: sessionStore,
                force: force
            )
            errorMessage = nil
        } catch ChatSyncError.missingSession {
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private var emptyChatState: some View {
        RunnerEmptyState(
            title: ChatThreadsCopy.emptyChatsTitle,
            description: ChatThreadsCopy.emptyChatsDescription,
            systemImage: "bubble.left.and.bubble.right",
            actionTitle: ChatThreadsCopy.newChatButtonTitle,
            action: { createThread() }
        )
    }

    private func consumeRequestedPromptIfNeeded() {
        guard let prompt = appNavigation.requestedChatPrompt else { return }
        if createThread(initialPrompt: prompt, shouldAutoSend: true) {
            appNavigation.requestedChatPrompt = nil
        }
    }

    /// Old task reply notifications used chat links. Resolve their persisted
    /// task identity and open Todos instead of leaking them into standalone chat.
    private func consumeRequestedThreadIfNeeded() async {
        guard let requestedID = appNavigation.requestedChatThreadID,
              let remoteID = UUID(uuidString: requestedID) else { return }
        do {
            let thread = try await chatSyncService.openThread(
                id: remoteID, modelContext: modelContext, sessionStore: sessionStore
            )
            guard appNavigation.requestedChatThreadID == requestedID else { return }
            if let todoID = thread.linkedTodoID {
                appNavigation.showTodo(todoID)
            } else if thread.isStandaloneChat {
                path.append(thread.id)
            }
            appNavigation.requestedChatThreadID = nil
        } catch is CancellationError {
        } catch {
            actionErrorMessage = MobileErrorCopy.message(for: error)
        }
    }

    @discardableResult
    private func createThread(initialPrompt: String? = nil, shouldAutoSend: Bool = false) -> Bool {
        actionErrorMessage = nil
        let thread = ChatThread(title: ChatThreadNaming.defaultTitle)
        modelContext.insert(thread)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionErrorMessage = ChatThreadsCopy.createFailedMessage
            return false
        }

        if let initialPrompt {
            pendingPromptByThreadID[thread.id] = PendingChatPrompt(
                message: initialPrompt,
                shouldAutoSend: shouldAutoSend
            )
        }
        path.append(thread.id)
        return true
    }

    private func deleteThreads(at offsets: IndexSet) {
        actionErrorMessage = nil
        for offset in offsets {
            modelContext.delete(filteredThreads[offset])
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionErrorMessage = ChatThreadsCopy.deleteFailedMessage(count: offsets.count)
        }
    }
}

enum ChatThreadsCopy {
    static let refreshWarningTitle = "Chat list may be out of date"
    static let refreshButtonTitle = "Refresh"
    static let actionWarningTitle = "Chat update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss chat update warning"
    static let createFailedMessage = "Could not start a new chat. Your chat list stayed unchanged."
    static let emptyChatsTitle = "Start a chat with Maraithon"
    static let emptyChatsDescription = "Ask about priorities, draft a follow-up, or turn loose notes into next actions."
    static let emptyThreadPreview = "Start with a priority, draft, or follow-up."
    static let noMatchingChatsTitle = "No chats match"
    static let noMatchingChatsDescription = "Try another name or message."
    static let deletedChatTitle = "Chat unavailable"
    static let deletedChatDescription = "This conversation was deleted or is no longer on this device."
    static let newChatButtonTitle = "New chat"

    static func deleteFailedMessage(count: Int) -> String {
        count == 1
            ? "Could not delete that chat. Your chat list stayed unchanged."
            : "Could not delete those chats. Your chat list stayed unchanged."
    }

    static var localSaveFailureLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            createFailedMessage,
            deleteFailedMessage(count: 1),
            deleteFailedMessage(count: 2)
        ]
    }

    static var emptyStateLabels: [String] {
        [
            emptyChatsTitle,
            emptyChatsDescription,
            emptyThreadPreview,
            noMatchingChatsTitle,
            noMatchingChatsDescription,
            deletedChatTitle,
            deletedChatDescription,
            newChatButtonTitle
        ]
    }
}

private struct PendingChatPrompt: Equatable {
    let message: String
    let shouldAutoSend: Bool
}
