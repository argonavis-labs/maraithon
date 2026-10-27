/// The conversation column: transcript on top, notices and the queued message
/// shelf, then the composer pinned at the bottom. The composer takes focus on
/// open so the user can start talking immediately.
import SwiftUI

struct TodoChatPane: View {
    @Bindable var store: TodoConversationStore
    let reconnect: () -> Void

    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader("Chat")
                .padding(.horizontal, Tokens.Spacing.large)
                .padding(.top, Tokens.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            conversation
            notices
            TodoConversationComposer(store: store, focused: $composerFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { composerFocused = true }
    }

    @ViewBuilder private var conversation: some View {
        if store.isLoading && store.thread == nil {
            VStack {
                Spacer()
                HStack(spacing: Tokens.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Opening your conversation…")
                        .font(Tokens.Typography.small)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                }
                .accessibilityElement(children: .combine)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.thread == nil {
            VStack {
                Spacer()
                RunnerEmptyState(
                    title: "Conversation could not load",
                    description: store.error ?? "Reconnect to continue this todo.",
                    actionTitle: "Retry",
                    action: reconnect
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TodoConversationTimeline(store: store)
        }
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.compact) {
            if let notice = store.connectionNotice {
                Text(notice)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
            }
            if let error = store.error, store.thread != nil {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.compact) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Tokens.Typography.caption)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Tokens.Typography.small)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tokens.Palette.destructiveText)
            }
            if let queued = store.queuedMessage {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.compact) {
                    Image(systemName: "clock")
                        .font(Tokens.Typography.caption)
                        .accessibilityHidden(true)
                    Text(queued.body)
                        .font(Tokens.Typography.small)
                        .lineLimit(1)
                    Spacer(minLength: Tokens.Spacing.small)
                    Button("Remove") { store.removeQueuedMessage() }
                        .buttonStyle(RunnerButtonStyle(.plain))
                }
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Queued until Maraithon finishes: \(queued.body)")
            }
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
