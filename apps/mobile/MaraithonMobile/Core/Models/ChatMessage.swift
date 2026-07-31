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

    var draftCard: ChatDraftCard? {
        storedMetadata?.draftCard
    }

    var linkedTodo: JSONValue? {
        storedMetadata?.linkedTodo
    }

    var workSummary: ChatWorkSummary? {
        storedMetadata?.workSummary
    }

    /// Decoding runs on every access and MessageBubble touches the derived
    /// properties several times per render, so memoize the decode per raw
    /// payload. The cache lives in a transient box so reads never trigger
    /// observation, and it invalidates automatically when `structuredData`
    /// changes.
    @Transient private var metadataCache = DecodedMetadataCache()

    /// `JSONDecoder` is stateless after configuration and safe to share.
    private nonisolated(unsafe) static let metadataDecoder = JSONDecoder()

    var storedMetadata: ChatMessageStoredMetadata? {
        guard let structuredData else { return nil }

        if metadataCache.raw == structuredData {
            return metadataCache.decoded
        }

        let decoded = try? Self.metadataDecoder.decode(ChatMessageStoredMetadata.self, from: structuredData)
        metadataCache.raw = structuredData
        metadataCache.decoded = decoded
        return decoded
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

/// Per-instance memo for the decoded `structuredData` payload. A reference-type
/// box keeps cache writes off the model's observed properties.
private final class DecodedMetadataCache {
    var raw: Data?
    var decoded: ChatMessageStoredMetadata?
}
