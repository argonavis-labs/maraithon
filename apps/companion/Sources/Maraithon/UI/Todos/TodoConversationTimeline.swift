/// The transcript: visible turns with Runner rhythm, the user's unsent message
/// as its own turn, and one live assistant turn while a run streams. Anchored
/// to the bottom so new text stays in view.
import SwiftUI

struct TodoConversationTimeline: View {
    let store: TodoConversationStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let messages = store.visibleMessages
                    if messages.isEmpty && store.pendingMessage == nil && !store.isThinking {
                        Text(TodoActionCopy.emptyConversation)
                            .font(Tokens.Typography.small)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        TodoConversationTurnView(message: message, store: store)
                            .padding(.top, index == 0 ? 0 : gap(before: message.role))
                            .id(message.id)
                    }
                    if let pending = store.pendingMessage {
                        TodoPendingTurnView(pending: pending, isSending: store.isSending) {
                            Task { await store.retrySend() }
                        }
                        .padding(.top, Tokens.TodoLayout.turnGapBeforeUser)
                    }
                    if store.isThinking {
                        TodoLiveRunView(store: store)
                            .padding(.top, Tokens.TodoLayout.turnGapBeforeAssistant)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.horizontal, Tokens.Spacing.large)
                .padding(.vertical, Tokens.Spacing.medium)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.thread?.messages.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: store.pendingMessage?.id) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: store.run?.workSummary?.preview?.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
        }
    }

    private func gap(before role: String) -> CGFloat {
        role == "user" ? Tokens.TodoLayout.turnGapBeforeUser : Tokens.TodoLayout.turnGapBeforeAssistant
    }
}

/// The user's message before the server confirms it. Reads like their turn,
/// with a quiet status line and a Retry that reuses the same message ID.
private struct TodoPendingTurnView: View {
    let pending: TodoConversationStore.PendingMessage
    let isSending: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.compact) {
            TodoUserBubble(text: pending.body)
            HStack(spacing: Tokens.Spacing.small) {
                if isSending {
                    ProgressView().controlSize(.mini)
                    Text("Sending…")
                } else {
                    Text("Not yet confirmed")
                    Button("Retry", action: retry)
                        .buttonStyle(RunnerButtonStyle(.plain))
                }
            }
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSending ? "Sending your message" : "Message not yet confirmed")
    }
}

/// The assistant's turn while a run is active: folded activity, the streamed
/// reply so far, and the working indicator driven by run status alone.
private struct TodoLiveRunView: View {
    let store: TodoConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            if let work = store.run?.workSummary, let calls = work.toolCalls, !calls.isEmpty {
                // The open group is the working line: headline, elapsed time,
                // and each step as it lands. Nothing repeats beneath it.
                RunnerActivityGroup(preview: work.headline ?? "Working…",
                                    steps: TodoActionCopy.activitySteps(work),
                                    expanded: true, live: true, since: store.runStartedAt)
                    .id(store.run?.id)
            } else {
                RunnerWorkingIndicator(label: store.run?.workSummary?.headline ?? "Working…", since: store.runStartedAt)
            }
            if let preview = store.run?.workSummary?.preview, !preview.isEmpty {
                RunnerMarkdownText(text: preview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
