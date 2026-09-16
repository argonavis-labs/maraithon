/// A next step from the brief, as an open card with a Prepare action or as a
/// compact row. Each sends its specific request into the task conversation.
import SwiftUI

struct TodoSuggestionCard: View {
    let action: CompanionTodoWorkspace.Action
    let store: TodoConversationStore
    let compact: Bool

    @State private var hovering = false

    private var disabled: Bool {
        store.thread == nil || store.isSending || store.pendingMessage != nil || store.isThinking
    }

    var body: some View {
        if compact { row } else { card }
    }

    private var card: some View {
        RunnerCard {
            VStack(alignment: .leading, spacing: Tokens.Spacing.snug) {
                HStack(alignment: .top, spacing: Tokens.Spacing.snug) {
                    TodoProviderMark(provider: action.provider, size: Tokens.IconSize.inline)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                        Text(action.label)
                            .font(Tokens.Typography.bodyMedium)
                            .foregroundStyle(Tokens.Palette.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(action.purpose)
                            .font(Tokens.Typography.small)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Prepare") { send() }
                        .buttonStyle(RunnerButtonStyle(.primary, compact: true))
                        .disabled(disabled)
                        .help("Have Maraithon prepare this for review")
                }
            }
            .runnerCardRow()
        }
    }

    private var row: some View {
        Button(action: send) {
            HStack(spacing: Tokens.Spacing.snug) {
                TodoProviderMark(provider: action.provider, size: Tokens.IconSize.inline)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                    Text(action.label)
                        .font(Tokens.Typography.bodyMedium)
                        .foregroundStyle(Tokens.Palette.foreground)
                        .lineLimit(1)
                    Text(action.purpose)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Spacing.small)
                HStack(spacing: Tokens.Spacing.xsmall) {
                    Text("Prepare")
                    Image(systemName: "arrow.up.right")
                        .font(Tokens.Typography.caption)
                        .accessibilityHidden(true)
                }
                .font(Tokens.Typography.small)
                .foregroundStyle(hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground)
            }
            .padding(.vertical, Tokens.Spacing.small)
            .padding(.horizontal, Tokens.SourcesLayout.cardRowHorizontalPadding)
            .background(hovering ? Tokens.Palette.foreground3 : .clear, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .strokeBorder(style: StrokeStyle(lineWidth: Tokens.Stroke.hairline, dash: [3, 3]))
                    .foregroundStyle(Tokens.Palette.ring)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(action.purpose)
        .accessibilityLabel("Prepare: \(action.label)")
    }

    private func send() {
        Task { await store.send(action.request) }
    }
}
