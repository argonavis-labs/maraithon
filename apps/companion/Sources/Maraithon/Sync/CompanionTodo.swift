import Foundation
import AssistantProgressKit

/// Task views use the paired-device API's status filters, with ownership
/// filtering applied locally after all pages have loaded.
enum TodoListFilter: String, CaseIterable, Identifiable, Sendable {
    case active
    case tracking
    case snoozed
    case done
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "Active"
        case .tracking: return "Tracking"
        case .snoozed: return "Snoozed"
        case .done: return "Completed"
        case .all: return "All tasks"
        }
    }

    var statusParameter: String { self == .tracking ? "active" : rawValue }

    /// Open work sorts by rank; history sorts by recency.
    var sortParameter: String {
        switch self {
        case .active, .tracking, .snoozed: return "rank"
        case .done, .all: return "updated"
        }
    }

    func includes(status: String) -> Bool {
        switch self {
        case .active, .tracking: return status == "open" || status == "snoozed"
        case .snoozed: return status == "snoozed"
        case .done: return status == "done"
        case .all: return true
        }
    }

    func includes(_ todo: CompanionTodo) -> Bool {
        includes(status: todo.status) && (self != .tracking || todo.isOwnedBySomeoneElse)
    }
}

/// Public Todo projection returned by the companion API. This intentionally
/// models only user-facing fields, including the curated resolution note.
struct CompanionTodo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let source: String
    let attentionMode: String?
    let title: String
    let summary: String?
    let nextAction: String?
    var notes: String? = nil
    let dueAt: String?
    let priority: Int
    let status: String
    var workflow: TodoWorkflow? = nil
    let snoozedUntil: String?
    let updatedAt: String?
    let actionCard: CompanionTodoActionCard?
    var closedAt: String? = nil
    var metadata: PublicMetadata? = nil
    var brief: CompanionTodoBrief? = nil
    /// `needs_you`, `can_prepare`, or `can_execute`; nil until the server
    /// projection ships the field, in which case no offer pill is shown.
    var agentActionability: String? = nil
    var agentActionLabel: String? = nil
    /// Server-computed decision signal that drives the "Decision" badge.
    var decision: Bool? = nil

    struct PublicMetadata: Codable, Hashable, Sendable {
        let resolutionNote: String?

        enum CodingKeys: String, CodingKey {
            case resolutionNote = "resolution_note"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case attentionMode = "attention_mode"
        case title
        case summary
        case nextAction = "next_action"
        case notes
        case dueAt = "due_at"
        case priority
        case status
        case workflow
        case snoozedUntil = "snoozed_until"
        case updatedAt = "updated_at"
        case actionCard = "action_card"
        case closedAt = "closed_at"
        case metadata
        case brief
        case agentActionability = "agent_actionability"
        case agentActionLabel = "agent_action_label"
        case decision
    }

    var recommendedMove: String? {
        if let next = Self.nonblank(workflow?.nextAction) { return next }
        guard canMarkDone else { return nil }
        if ["manual", "mobile"].contains(source) {
            return Self.nonblank(nextAction) ?? Self.nonblank(actionCard?.nextBestAction)
        }
        return Self.nonblank(actionCard?.nextBestAction) ?? Self.nonblank(nextAction)
    }

    var dueDate: Date? { Self.parseDate(dueAt) }
    var updatedDate: Date? { Self.parseDate(updatedAt) }
    var closedDate: Date? { Self.parseDate(closedAt) }
    var resolutionNote: String? { Self.nonblank(metadata?.resolutionNote) }

    var isOwnedBySomeoneElse: Bool { workflow?.owner.kind == "person" }
    var isTracking: Bool { canMarkDone && isOwnedBySomeoneElse }
    var needsDecision: Bool { decision == true && !isOwnedBySomeoneElse }

    var canMarkDone: Bool { status == "open" || status == "snoozed" }
    var canReopen: Bool { status == "done" }
    var canDismiss: Bool { status == "open" || status == "snoozed" }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

/// High-signal action-card fields shared with the web and mobile work-item
/// surfaces. The server may add fields without breaking this decoder.
struct CompanionTodoActionCard: Codable, Hashable, Sendable {
    let headline: String?
    let decisionPrompt: String?
    let whyNow: String?
    let nextBestAction: String?
    let draftPreview: String?
    let sourceContext: String?
    let evidenceExcerpt: String?
    let sourceAction: CompanionTodoSourceAction?

    enum CodingKeys: String, CodingKey {
        case headline
        case decisionPrompt = "decision_prompt"
        case whyNow = "why_now"
        case nextBestAction = "next_best_action"
        case draftPreview = "draft_preview"
        case sourceContext = "source_context"
        case evidenceExcerpt = "evidence_excerpt"
        case sourceAction = "source_action"
    }
}

struct CompanionTodoSourceAction: Codable, Hashable, Sendable {
    let openURL: String?
    let openLabel: String?
    let draftText: String?
    var provider: String? = nil
    var subject: String? = nil
    var recipient: String? = nil

    enum CodingKeys: String, CodingKey {
        case openURL = "open_url"
        case openLabel = "open_label"
        case draftText = "draft_text"
        case provider, subject, recipient
    }

    var destination: URL? {
        guard let openURL, let url = URL(string: openURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http", "slack", "sms"].contains(scheme) else { return nil }
        return url
    }
}

struct CompanionTodoDetailsResponse: Codable, Sendable {
    let todo: CompanionTodo
}

struct CompanionTodosResponse: Codable, Sendable {
    let todos: [CompanionTodo]
    let pagination: CompanionTodoPagination
}

struct CompanionTodoPagination: Codable, Sendable {
    let limit: Int
    let offset: Int
    let count: Int
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case limit
        case offset
        case count
        case nextOffset = "next_offset"
    }
}

enum CompanionTodoAction: String, Sendable {
    case done
    case dismiss
    case reopen
}

struct CompanionTodoActionResponse: Codable, Sendable {
    let action: String
    let todo: CompanionTodo
}
