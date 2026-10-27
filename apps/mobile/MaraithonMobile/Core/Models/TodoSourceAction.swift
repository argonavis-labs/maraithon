import Foundation

/// The prepared channel action for a work item: where it came from, the full
/// suggested wording, and the deep link back into the source app.
struct TodoSourceAction: Equatable {
    var provider: String?
    var providerLabel: String?
    var openURLString: String?
    var openLabel: String?
    var draftText: String?
    var draftKind: String?
    var recipient: String?
    var recipientHandle: String?
    var subject: String?
    var participants: [CardParticipant] = []
    var conversation: [CardConversationMessage] = []

    var openURL: URL? {
        guard let openURLString, !openURLString.isEmpty else { return nil }
        return URL(string: openURLString)
    }

    var hasDraft: Bool {
        draftText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isEmpty: Bool {
        !hasDraft && openURL == nil
    }

    var headline: String {
        switch draftKind {
        case "reply": "Suggested reply"
        case "draft": "Suggested draft"
        case "next_step": "Suggested next step"
        default: hasDraft ? "Suggested wording" : "Source"
        }
    }

    var subtitle: String? {
        let parts = [providerLabel, recipient, subject].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Prefers the native Messages composer over the `sms:` deep link so the
    /// draft body can be prefilled.
    var prefersMessageCompose: Bool {
        provider == "imessage" && recipientHandle?.isEmpty == false && hasDraft
    }
}
