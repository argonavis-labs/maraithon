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
    @State private var pendingPromptByThreadID: [UUID: PendingChatPrompt] = [:]

    private let chatSyncService = ChatSyncService()

    private var filteredThreads: [ChatThread] {
        ChatThreadFiltering.filter(threads, searchText: searchText)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }

                if filteredThreads.isEmpty {
                    if threads.isEmpty {
                        emptyChatState
                    } else {
                        ContentUnavailableView(
                            "No Matching Chats",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Try a different search.")
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
                        "Chat Deleted",
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: Text("This conversation is no longer available.")
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
                    .accessibilityLabel("New Chat")
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
            errorMessage = error.localizedDescription
        }
    }

    private var emptyChatState: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("No Chats", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Ask Maraithon to plan the day, draft a follow-up, or capture a next action.")
            }

            Button {
                createThread()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
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
        appNavigation.requestedChatPrompt = nil
        createThread(initialPrompt: prompt, shouldAutoSend: true)
    }

    private func createThread(initialPrompt: String? = nil, shouldAutoSend: Bool = false) {
        let thread = ChatThread(title: "New conversation")
        modelContext.insert(thread)
        try? modelContext.save()
        if let initialPrompt {
            pendingPromptByThreadID[thread.id] = PendingChatPrompt(
                message: initialPrompt,
                shouldAutoSend: shouldAutoSend
            )
        }
        path.append(thread.id)
    }

    private func deleteThreads(at offsets: IndexSet) {
        for offset in offsets {
            modelContext.delete(filteredThreads[offset])
        }
        try? modelContext.save()
    }
}

private struct PendingChatPrompt: Equatable {
    let message: String
    let shouldAutoSend: Bool
}
