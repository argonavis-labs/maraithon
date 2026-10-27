/// Copy for the action cards and chat turns: provider names, review status
/// tones, the prompts the workspace sends on the user's behalf, and the
/// collapsed activity line. Keeps wording out of the views.
import Foundation

enum TodoActionCopy {
    static let emptyConversation = "Tell Maraithon what to do with this task. Try “Add this to my calendar tomorrow.”"
    static let composerPlaceholder = "Tell Maraithon what to do…"
    static let composerHint = "Return to send · Shift-Return for a new line"
    static let composerBusyHint = "Maraithon is working. A new message sends when it finishes."

    static func askAboutPerson(_ name: String) -> String {
        "Who is \(name), how do I know them, and what should I know for this todo? Check our real relationship and source history."
    }

    static func prepareEmailPrompt(_ card: CompanionConversationDraft, recipient: String, subject: String,
                                   cc: String, bcc: String, body: String) -> String {
        "Save this reviewed email as a Gmail draft and prepare its approval card. Do not send. Keep the original thread context. From: \(card.from ?? "the source account")\nTo: \(recipient)\nSubject: \(subject)\nCc: \(cc)\nBcc: \(bcc)\n\n\(body)"
    }

    static func providerLabel(_ provider: String) -> String {
        switch provider {
        case "gmail": return "Gmail"
        case "imessage": return "Messages"
        case "slack": return "Slack"
        case "browser": return "Local Chrome"
        case "calendar": return "Calendar"
        default: return "Action"
        }
    }

    static func reviewTitle(_ card: CompanionConversationDraft) -> String {
        card.title ?? providerLabel(card.provider)
    }

    static func reviewStatus(_ card: CompanionConversationDraft) -> String {
        card.status ?? "Review draft"
    }

    static func reviewTone(_ card: CompanionConversationDraft) -> RunnerBadge.Tone {
        switch card.status {
        case "Sent", "Completed", "Saved to calendar": return .emerald
        case "Could not send", "Could not complete": return .red
        case "Check before retrying": return .amber
        default: return card.connectionRequired == true ? .amber : .zinc
        }
    }

    static func confirmLabel(_ card: CompanionConversationDraft) -> String {
        card.provider == "gmail" ? "Send email" : (card.sendLabel ?? "Confirm action")
    }

    static func confirmMessage(_ card: CompanionConversationDraft, recipient: String) -> String {
        switch card.provider {
        case "browser": return "Run the exact browser step shown here on your Mac."
        case "calendar": return "Save the calendar change shown here."
        default: return "Send the reviewed message to \(recipient)."
        }
    }

    static func reviewReference(_ card: CompanionConversationDraft) -> String {
        TodoActionPlan.isTerminal(card)
            ? "\(reviewTitle(card)) · \(reviewStatus(card))"
            : "Review \(providerLabel(card.provider)) draft"
    }

    /// The collapsed activity line: the live step while running, otherwise the
    /// server headline with a failure count.
    static func activityPreview(_ work: CompanionConversation.Work) -> String {
        let calls = work.toolCalls ?? []
        if let live = calls.first(where: { $0.status == "running" }), let label = live.label {
            return live.detail.map { "\(label) · \($0)" } ?? label
        }
        let failed = calls.filter { $0.status == "failed" }.count
        let headline = work.headline ?? "Supporting work"
        return failed > 0 ? "\(headline) · \(failed) failed" : headline
    }

    static func activitySteps(_ work: CompanionConversation.Work) -> [RunnerActivityGroup.Step] {
        (work.toolCalls ?? []).enumerated().compactMap { index, call in
            guard let label = call.label else { return nil }
            return RunnerActivityGroup.Step(id: index, label: label, status: call.status,
                                            summary: call.summary, detail: call.detail)
        }
    }

    static func turnTime(_ raw: String?) -> String? {
        CompanionConversation.date(from: raw)?.formatted(date: .omitted, time: .shortened)
    }

    static func turnTimeFull(_ raw: String?) -> String? {
        CompanionConversation.date(from: raw)?.formatted(date: .abbreviated, time: .shortened)
    }

    static func eventDate(_ raw: String, timezone: String?) -> String {
        guard let date = CompanionConversation.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }
}
