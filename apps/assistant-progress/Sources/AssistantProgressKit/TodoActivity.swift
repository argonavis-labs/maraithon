/// Durable todo history shared by Mac and iPhone. Missing dates stay undated;
/// a draft, a send acknowledgement, and a reply remain distinct events.
import Foundation

public struct TodoActivity: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let body: String?
    public let occurredAt: String?
    public let provider: String?
    public let messageID: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, provider
        case occurredAt = "occurred_at", messageID = "message_id"
    }

    public var date: Date? {
        guard let occurredAt else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: occurredAt) ?? ISO8601DateFormatter().date(from: occurredAt)
    }

    public var symbol: String {
        switch kind {
        case "created": return "sparkle"
        case "chat", "assistant": return "bubble.left"
        case "draft": return "square.and.pencil"
        case "sent": return "checkmark.circle"
        case "cancelled", "expired": return "xmark.circle"
        case "reply": return "arrow.turn.down.left"
        case "sending": return "paperplane"
        case "unknown", "failed": return "exclamationmark.circle"
        case "marked_done": return "checkmark.circle.fill"
        default: return "clock"
        }
    }
}
