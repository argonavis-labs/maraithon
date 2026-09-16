/// Chooses the one or two cards the workspace shows. Live reviews win over
/// suggestions, the review the user focused moves first, and nothing else is a
/// card. Finished reviews only appear as references in the conversation.
import Foundation

struct TodoActionPlan {
    enum Slot: Identifiable {
        case review(CompanionConversation.Message, CompanionConversationDraft)
        case suggestion(CompanionTodoWorkspace.Action)

        var id: String {
            switch self {
            case .review(let message, _): return "review:" + message.id
            case .suggestion(let action): return "suggestion:" + action.id
            }
        }
    }

    let primary: Slot?
    let secondary: Slot?

    /// Draft statuses the server uses once a card no longer needs a decision.
    static let terminalStatuses: Set<String> = [
        "Completed", "Running", "Saving", "Could not complete", "Sent", "Saved to calendar",
        "Cancelled", "Expired", "Sending", "Could not send", "Check before retrying"
    ]

    static func isTerminal(_ card: CompanionConversationDraft) -> Bool {
        card.status.map { terminalStatuses.contains($0) } ?? false
    }

    static func make(todo: CompanionTodo, messages: [CompanionConversation.Message],
                     preferredReviewID: String?) -> TodoActionPlan {
        guard todo.canMarkDone else { return TodoActionPlan(primary: nil, secondary: nil) }
        var reviews: [(CompanionConversation.Message, CompanionConversationDraft)] = messages.reversed().compactMap { message in
            guard let card = message.draftCard, !isTerminal(card) else { return nil }
            return (message, card)
        }
        if let preferredReviewID, let index = reviews.firstIndex(where: { $0.0.id == preferredReviewID }), index > 0 {
            reviews.insert(reviews.remove(at: index), at: 0)
        }
        // An older draft for the same provider and target is a stale copy of
        // the newer one, not a second action. Keep only the first of each.
        var seenTargets = Set<String>()
        reviews = reviews.filter { _, card in
            let target = (card.recipient ?? card.title ?? "").lowercased()
            return seenTargets.insert(card.provider + "|" + target).inserted
        }
        let suggestions = (todo.brief?.suggestedActions ?? []).filter { action in
            !reviews.contains { covers($0.1, action) }
        }
        let slots: [Slot] = reviews.map { .review($0.0, $0.1) } + suggestions.map { .suggestion($0) }
        return TodoActionPlan(primary: slots.first, secondary: slots.count > 1 ? slots[1] : nil)
    }

    /// Mirrors the web workspace: a suggestion is redundant while a live card
    /// already targets the same provider and person. Email cards often carry
    /// only an address, so any name token of three or more letters counts.
    static func covers(_ card: CompanionConversationDraft, _ action: CompanionTodoWorkspace.Action) -> Bool {
        guard card.provider == action.provider else { return false }
        guard let name = action.personName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return true }
        let tokens = name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        let haystack = [card.recipient, card.recipientName, card.title, card.subject]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return tokens.isEmpty || tokens.contains { haystack.contains($0) }
    }
}
