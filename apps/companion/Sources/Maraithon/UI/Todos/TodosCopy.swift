import SwiftUI

/// User-facing Todo labels shared by the Mac list, workspace, and inspector.
enum TodosCopy {
    static func resultCount(_ count: Int, filter: TodoListFilter) -> String {
        let noun = count == 1 ? "work item" : "work items"
        switch filter {
        case .active: return "\(count) active \(noun)"
        case .tracking: return "\(count) tracked \(noun)"
        case .snoozed: return "\(count) snoozed \(noun)"
        case .done: return "\(count) completed \(noun)"
        case .all: return "\(count) \(noun)"
        }
    }

    static func showingLine(count: Int, isLoading: Bool) -> String {
        if isLoading && count == 0 { return "Loading tasks…" }
        let noun = count == 1 ? "work item" : "work items"
        return "Showing \(count) matching \(noun)."
    }

    static func emptyTitle(filter: TodoListFilter, query: String) -> String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching tasks"
        }
        switch filter {
        case .active: return "Your open work list is clear"
        case .tracking: return "No work is being tracked"
        case .snoozed: return "Nothing is snoozed"
        case .done: return "No completed work yet"
        case .all: return "No tasks yet"
        }
    }

    static func emptyDescription(filter: TodoListFilter, query: String) -> String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try another title, next action, or source."
        }
        switch filter {
        case .active: return "Maraithon will surface commitments when the next move is clear."
        case .tracking: return "Work owned by someone else will appear here so you can follow its progress."
        case .snoozed: return "Snoozed tasks return here until their review date."
        case .done: return "Completed work will appear here and can be reopened."
        case .all: return "Tasks from your inbox, calendar, and Slack will land here."
        }
    }

    static func sourceLabel(_ source: String) -> String {
        let key = source.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? source
        switch key {
        case "gmail", "gmail_thread": return "Gmail"
        case "google_calendar", "calendar", "calendar_local": return "Calendar"
        case "imessage": return "iMessage"
        case "messages": return "Messages"
        case "browser": return "Browser"
        case "browser_history": return "Browser History"
        case "voice_memos": return "Voice Memos"
        case "manual": return "Added by you"
        case "mobile": return "Added on iPhone"
        case "desktop": return "Mac companion"
        case "chief_of_staff_morning_briefing": return "Morning briefing"
        case "chief_of_staff_commitment_tracker": return "Open work review"
        case "chief_of_staff_holiday": return "Holiday review"
        case "chief_of_staff_weekend": return "Weekend review"
        case "runtime", "system", "telegram_assistant": return "Maraithon"
        default:
            return key
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func attentionLabel(_ value: String?) -> String {
        value == "monitor" ? "Watching" : "Needs action"
    }

    static func statusLabel(_ value: String) -> String {
        switch value {
        case "open": return "Open"
        case "snoozed": return "Snoozed"
        case "done": return "Done"
        case "dismissed": return "Dismissed"
        default: return value.capitalized
        }
    }

    static func statusTone(_ value: String) -> RunnerBadge.Tone {
        switch value {
        case "open": return .emerald
        case "snoozed": return .amber
        case "done": return .blue
        default: return .zinc
        }
    }

    static func priorityLabel(_ priority: Int) -> String {
        switch priority {
        case 90...: return "Critical"
        case 75...: return "High"
        default: return "Normal"
        }
    }

    static func priorityTone(_ priority: Int) -> RunnerBadge.Tone {
        priority >= 90 ? .red : .amber
    }

    static func nextActionLabel(_ todo: CompanionTodo) -> String {
        if todo.isOwnedBySomeoneElse { return "Owner’s next step" }
        return todo.needsDecision ? "Recommended" : "Next"
    }

    static func ownershipLabel(_ todo: CompanionTodo) -> String? {
        guard let workflow = todo.workflow else { return nil }
        return todo.isOwnedBySomeoneElse ? "Owned by \(workflow.owner.displayName)" : workflow.ballLabel
    }

    /// Work owned by others shows monitoring rather than an offer to act.
    /// User-owned work uses the server's actionability label when present.
    static func agentOfferLabel(_ todo: CompanionTodo) -> String? {
        if todo.isOwnedBySomeoneElse { return todo.isTracking ? "Tracking progress" : nil }
        guard let actionability = todo.agentActionability else { return nil }
        if let label = todo.agentActionLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        switch actionability {
        case "can_prepare": return "Maraithon can prepare"
        case "can_execute": return "Maraithon can execute"
        default: return "Needs you"
        }
    }

    static func agentOfferTone(_ todo: CompanionTodo) -> RunnerBadge.Tone {
        if todo.isOwnedBySomeoneElse { return .zinc }
        switch todo.agentActionability {
        case "can_prepare": return .blue
        case "can_execute": return .emerald
        default: return .zinc
        }
    }

    static func dueLabel(_ date: Date?, active: Bool = true) -> String {
        guard let date else { return "No due date" }
        if active && date < Date() {
            return "Overdue " + date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Table cell form: Today / Tomorrow / Yesterday / `Sep 10`.
    static func compactDue(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "No due date" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    static func dueTone(_ date: Date?, active: Bool = true) -> StatusTone {
        guard active, let date else { return .muted }
        return date < Date() ? .error : .muted
    }

    static func dueColor(_ date: Date?, active: Bool = true, now: Date = Date()) -> Color {
        guard active, let date, date < now else { return Tokens.Palette.mutedForeground }
        return Tokens.Palette.destructiveText
    }
}
