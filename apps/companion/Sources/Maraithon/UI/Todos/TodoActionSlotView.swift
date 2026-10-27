/// Renders one slot of the action plan: the primary slot opens (a review card
/// or a suggestion card); the secondary slot stays a single compact row.
import SwiftUI

struct TodoActionSlotView: View {
    let slot: TodoActionPlan.Slot
    let store: TodoConversationStore
    let isPrimary: Bool

    var body: some View {
        switch slot {
        case .review(let message, let card):
            if isPrimary {
                TodoReviewCard(draft: card, store: store, messageID: message.id)
                    .id(message.id + (card.preparedActionID ?? "draft"))
            } else {
                TodoReviewRow(card: card) { store.preferredReviewID = message.id }
            }
        case .suggestion(let action):
            TodoSuggestionCard(action: action, store: store, compact: !isPrimary)
        }
    }
}

/// A live review that is not open: title, status, and a Review action that
/// swaps it into the primary slot. Nothing sends from here.
private struct TodoReviewRow: View {
    let card: CompanionConversationDraft
    let focus: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: focus) {
            HStack(spacing: Tokens.Spacing.snug) {
                TodoProviderMark(provider: card.provider, size: Tokens.IconSize.inline)
                Text(TodoActionCopy.reviewTitle(card))
                    .font(Tokens.Typography.bodyMedium)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Spacing.small)
                RunnerBadge(text: TodoActionCopy.reviewStatus(card), tone: TodoActionCopy.reviewTone(card))
                Text("Review")
                    .font(Tokens.Typography.small)
                    .foregroundStyle(hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground)
            }
            .padding(.vertical, Tokens.Spacing.small)
            .padding(.horizontal, Tokens.SourcesLayout.cardRowHorizontalPadding)
            .background(hovering ? Tokens.Palette.foreground3 : .clear, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Review \(TodoActionCopy.reviewTitle(card)), \(TodoActionCopy.reviewStatus(card))")
    }
}
