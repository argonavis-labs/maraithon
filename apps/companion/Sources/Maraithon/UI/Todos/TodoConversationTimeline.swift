/// A readable conversation with persisted evidence summaries and reviewable next actions.
import SwiftUI

struct TodoConversationTimeline: View {
    let store: TodoConversationStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.large) {
                    ForEach(store.thread?.messages ?? []) { message in
                        TodoConversationMessageView(message: message, store: store).id(message.id)
                    }
                    if let pending = store.pendingMessage {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                            Label(store.isSending ? "Sending…" : "Not yet confirmed", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(pending.body).textSelection(.enabled)
                            if !store.isSending {
                                Button("Retry message", systemImage: "arrow.clockwise") { Task { await store.retrySend() } }
                            }
                        }
                    }
                    if store.isThinking {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                            ProgressView(store.run?.workSummary?.headline ?? "Working on this with you…")
                                .controlSize(.small)
                            if let preview = store.run?.workSummary?.preview, !preview.isEmpty {
                                Text(preview).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .frame(maxWidth: Tokens.Layout.todoConversationWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(Tokens.Spacing.large)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.thread?.messages.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: store.pendingMessage?.id) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
        }
    }
}
