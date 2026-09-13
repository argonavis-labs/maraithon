/// Durable todo conversation payloads. Action previews are separate from confirmed outcomes.
import Foundation
import AssistantProgressKit

struct CompanionConversation: Decodable, Sendable {
    let id: String
    let title: String
    let messages: [Message]
    let pendingRun: Run?
    let linkedTodo: LinkedTodo?

    struct LinkedTodo: Decodable, Sendable {
        let id: String
        let workflow: TodoWorkflow?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case pendingRun = "pending_run", linkedTodo = "linked_todo"
    }

    struct Message: Decodable, Identifiable, Sendable {
        let id: String
        let role: String
        let body: String
        let clientMessageID: String?
        let messageClass: String?
        let sentAt: String?
        let actions: [Action]
        let structuredData: Content?
        let workSummary: Work?
        enum CodingKeys: String, CodingKey {
            case id, role, body, actions
            case clientMessageID = "client_message_id"
            case messageClass = "message_class", sentAt = "sent_at"
            case structuredData = "structured_data", workSummary = "work_summary"
        }
        struct Content: Decodable, Sendable {
            let draftCard: CompanionConversationDraft?
            enum CodingKeys: String, CodingKey { case draftCard = "draft_card" }
        }
        var draftCard: CompanionConversationDraft? { structuredData?.draftCard }
        var isPrimer: Bool { messageClass == "todo_chat_primer" }
    }

    struct Action: Decodable, Identifiable, Sendable {
        let id: String
        let kind: String
        let label: String
        let decision: String
    }

    struct Run: Decodable, Sendable {
        let id: String
        let status: String
        let error: String?
        let startedAt: String?
        let workSummary: Work?
        var isActive: Bool { ["queued", "running"].contains(status) }
        enum CodingKeys: String, CodingKey {
            case id, status, error
            case startedAt = "started_at", workSummary = "work_summary"
        }
        /// Same run with streamed reply text attached; snapshots drop it.
        func withPreview(_ preview: String?) -> Run {
            Run(id: id, status: status, error: error, startedAt: startedAt,
                workSummary: Work(headline: workSummary?.headline, preview: preview, toolCalls: workSummary?.toolCalls))
        }
    }

    struct Work: Decodable, Sendable {
        let headline: String?
        let preview: String?
        let toolCalls: [Step]?
        enum CodingKeys: String, CodingKey {
            case headline, preview
            case toolCalls = "tool_calls"
        }
        struct Step: Decodable, Sendable {
            let label: String?
            let status: String?
            let summary: String?
            let detail: String?
        }
    }

    struct Response: Decodable, Sendable {
        let thread: CompanionConversation
        let run: Run?
    }

    /// Server timestamps arrive as ISO 8601 with or without fractional seconds.
    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
