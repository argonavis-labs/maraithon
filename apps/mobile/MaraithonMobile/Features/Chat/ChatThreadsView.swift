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

    private var filteredThreads: [ChatThread] {
        ChatThreadFiltering.filter(threads, searchText: searchText)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorMessage {
                    Section {
                        SyncIssueBanner(
                            title: ChatThreadsCopy.refreshWarningTitle,
                            message: errorMessage,
                            buttonTitle: ChatThreadsCopy.refreshButtonTitle,
                            retry: { Task { await refreshThreads() } },
                            dismiss: { self.errorMessage = nil }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                if let actionErrorMessage {
                    Section {
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
                    }
                }

                if filteredThreads.isEmpty {
                    if threads.isEmpty {
                        emptyChatState
                    } else {
                        ContentUnavailableView(
                            ChatThreadsCopy.noMatchingChatsTitle,
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(ChatThreadsCopy.noMatchingChatsDescription)
                        )
                    }
                } else {
                    ForEach(filteredThreads) { thread in
                        NavigationLink(value: thread.id) {
                            ChatThreadRow(thread: thread)
                        }
                    }
                    .onDelete(perform: deleteThreads)
                }
            }
            .navigationTitle("Chat")
            .searchable(text: $searchText, prompt: "Search chats")
            .refreshable {
                await refreshThreads()
            }
            .task {
                await refreshThreads()
            }
            .onAppear(perform: consumeRequestedPromptIfNeeded)
            .onChange(of: appNavigation.requestedChatPrompt) { _, _ in
                consumeRequestedPromptIfNeeded()
            }
            .navigationDestination(for: UUID.self) { threadID in
                if let thread = threads.first(where: { $0.id == threadID }) {
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
                    ContentUnavailableView(
                        ChatThreadsCopy.deletedChatTitle,
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: Text(ChatThreadsCopy.deletedChatDescription)
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createThread()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(ChatThreadsCopy.newChatButtonTitle)
                }
            }
        }
    }

    private func refreshThreads() async {
        do {
            try await chatSyncService.refreshThreads(
                modelContext: modelContext,
                sessionStore: sessionStore
            )
            errorMessage = nil
        } catch ChatSyncError.missingSession {
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private var emptyChatState: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label(ChatThreadsCopy.emptyChatsTitle, systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(ChatThreadsCopy.emptyChatsDescription)
            }

            Button {
                createThread()
            } label: {
                Label(ChatThreadsCopy.newChatButtonTitle, systemImage: "square.and.pencil")
                    .font(.headline)
            }
            .appProminentGlassActionStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }

    private func consumeRequestedPromptIfNeeded() {
        guard let prompt = appNavigation.requestedChatPrompt else { return }
        if createThread(initialPrompt: prompt, shouldAutoSend: true) {
            appNavigation.requestedChatPrompt = nil
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
    static let emptyChatsTitle = "No chats yet"
    static let emptyChatsDescription = "Start a chat to plan the day, draft a follow-up, or turn loose notes into next actions."
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
