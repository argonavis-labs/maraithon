import Foundation

struct ChatMessageStoredMetadata: Codable, Equatable {
    var actions: [ChatMessageAction] = []
    var linkedTodo: JSONValue?
    var structuredData: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case actions
        case linkedTodo = "linked_todo"
        case structuredData = "structured_data"
    }
}

struct ChatMessageAction: Codable, Equatable, Identifiable {
    let actionID: UUID
    let kind: String
    let label: String
    let decisionRawValue: String
    let style: String

    var id: String {
        "\(actionID.uuidString)-\(decisionRawValue)"
    }

    var decision: ChatActionDecision? {
        ChatActionDecision(rawValue: decisionRawValue)
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "id"
        case kind
        case label
        case decisionRawValue = "decision"
        case style
    }
}
