import Foundation
import SwiftData

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var body: String
    var sentAt: Date
    var roleRawValue: String
    var remoteID: UUID?
    var clientMessageID: UUID?
    var deliveryStateRawValue: String?
    var turnKind: String?
    var messageClass: String?
    var remoteRunID: UUID?
    var structuredData: Data?
    var thread: ChatThread?

    var role: ChatRole {
        get { ChatRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    var deliveryState: ChatDeliveryState {
        get { ChatDeliveryState(rawValue: deliveryStateRawValue ?? "") ?? .delivered }
        set { deliveryStateRawValue = newValue.rawValue }
    }

    var actions: [ChatMessageAction] {
        storedMetadata?.actions ?? []
    }

    var linkedTodo: JSONValue? {
        storedMetadata?.linkedTodo
    }

    var storedMetadata: ChatMessageStoredMetadata? {
        guard let structuredData else { return nil }
        return try? JSONDecoder().decode(ChatMessageStoredMetadata.self, from: structuredData)
    }

    init(
        id: UUID = UUID(),
        body: String,
        sentAt: Date = Date(),
        role: ChatRole,
        remoteID: UUID? = nil,
        clientMessageID: UUID? = nil,
        deliveryState: ChatDeliveryState = .delivered,
        turnKind: String? = nil,
        messageClass: String? = nil,
        remoteRunID: UUID? = nil,
        structuredData: Data? = nil,
        thread: ChatThread? = nil
    ) {
        self.id = id
        self.body = body
        self.sentAt = sentAt
        self.roleRawValue = role.rawValue
        self.remoteID = remoteID
        self.clientMessageID = clientMessageID
        self.deliveryStateRawValue = deliveryState.rawValue
        self.turnKind = turnKind
        self.messageClass = messageClass
        self.remoteRunID = remoteRunID
        self.structuredData = structuredData
        self.thread = thread
    }
}
