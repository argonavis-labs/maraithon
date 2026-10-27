/// One conversation turn. The user's words sit in a quiet bubble on the
/// right; Maraithon's reply is chromeless prose with its work folded into one
/// line and any draft reduced to a single reference. Timestamps show on hover.
import SwiftUI

struct TodoConversationTurnView: View {
    let message: CompanionConversation.Message
    let store: TodoConversationStore

    @State private var hovering = false

    private var isUser: Bool { message.role == "user" }
    private var showsBody: Bool {
        !message.isPrimer && !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: Tokens.Spacing.compact) {
            if isUser {
                TodoUserBubble(text: message.body)
            } else {
                assistant
            }
            if let time = TodoActionCopy.turnTime(message.sentAt) {
                Text(time)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .opacity(hovering ? 1 : 0)
                    .help(TodoActionCopy.turnTimeFull(message.sentAt) ?? time)
                    .accessibilityLabel("Sent \(time)")
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "You" : "Maraithon")
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            if let work = message.workSummary, let calls = work.toolCalls, !calls.isEmpty {
                RunnerActivityGroup(preview: TodoActionCopy.activityPreview(work),
                                    steps: TodoActionCopy.activitySteps(work))
            }
            if showsBody {
                RunnerMarkdownText(text: message.body)
            }
            if let card = message.draftCard {
                cardReference(card)
            } else {
                decisions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func cardReference(_ card: CompanionConversationDraft) -> some View {
        if TodoActionPlan.isTerminal(card) {
            HStack(spacing: Tokens.Spacing.compact) {
                TodoProviderMark(provider: card.provider, size: Tokens.IconSize.providerMark)
                Text(TodoActionCopy.reviewReference(card))
                    .lineLimit(1)
            }
            .font(Tokens.Typography.small)
            .foregroundStyle(Tokens.Palette.mutedForeground)
            .accessibilityElement(children: .combine)
        } else {
            Button {
                store.preferredReviewID = message.id
            } label: {
                HStack(spacing: Tokens.Spacing.compact) {
                    TodoProviderMark(provider: card.provider, size: Tokens.IconSize.providerMark)
                    Text(TodoActionCopy.reviewReference(card))
                }
            }
            .buttonStyle(RunnerButtonStyle(.plain))
            .help("Open this draft in the next action")
        }
    }

    @ViewBuilder private var decisions: some View {
        let actions = message.actions.filter { $0.kind == "prepared_action_decision" }
        if !actions.isEmpty {
            HStack(spacing: Tokens.Spacing.small) {
                ForEach(actions) { action in
                    Button(action.label) {
                        Task { await store.decide(id: action.id, decision: action.decision, edits: [:]) }
                    }
                    .buttonStyle(RunnerButtonStyle(action.decision == "confirm" ? .primary : .secondary, compact: true))
                    .disabled(store.decidingActionID != nil)
                }
            }
        }
    }
}

/// The user's side of the conversation: a 5% ink bubble, right-aligned, no
/// wider than most of the pane. Shared by confirmed and pending turns.
struct TodoUserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(Tokens.Typography.body)
                .lineSpacing(Tokens.TodoLayout.proseLineSpacing)
                .foregroundStyle(Tokens.Palette.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Tokens.Spacing.tight)
                .padding(.vertical, Tokens.Spacing.snug)
                .background(Tokens.Palette.foreground5, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.medium))
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in
            length * Tokens.TodoLayout.bubbleMaxWidthFraction
        }
    }
}
