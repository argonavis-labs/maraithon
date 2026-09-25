/// Reviewable message or calendar proposal. Only server-issued action IDs can execute remotely.
import Foundation

struct CompanionConversationDraft: Decodable, Sendable {
    let provider: String
    let title: String?
    let status: String?
    let from: String?
    let recipient: String?
    let recipientName: String?
    let subject: String?
    let body: String?
    let cc: String?
    let bcc: String?
    let preparedActionID: String?
    let sendLabel: String?
    let startAt: String?
    let endAt: String?
    let timezone: String?
    let actionType: String?
    let editable: Bool?
    let connectionRequired: Bool?
    let connectionLabel: String?
    let connectionNotice: String?
    let connectionURL: String?
    let conversation: [ConversationMessage]?
    let deliveryNote: String?
    struct ConversationMessage: Decodable, Sendable {
        let speaker: String?
        let text: String
        let at: String?
        let fromUser: Bool?
        enum CodingKeys: String, CodingKey { case speaker, text, at; case fromUser = "from_user" }
    }
    var isEditable: Bool { provider != "browser" && (editable == true || preparedActionID != nil || provider == "imessage") }
    enum CodingKeys: String, CodingKey {
        case provider, title, status, from, recipient, subject, body, cc, bcc, timezone, editable, conversation
        case deliveryNote = "delivery_note"
        case recipientName = "recipient_name", preparedActionID = "prepared_action_id"
        case sendLabel = "send_label", startAt = "start_at", endAt = "end_at", actionType = "action_type"
        case connectionRequired = "connection_required", connectionLabel = "connection_label"
        case connectionNotice = "connection_notice", connectionURL = "connection_url"
    }
}
