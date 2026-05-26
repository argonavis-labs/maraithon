import Foundation
import SwiftData

@Model
final class ChatThread {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var remoteID: UUID?
    var remoteStatusRawValue: String?
    var syncStatusRawValue: String?
    var pendingRunID: UUID?
    var lastSyncedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread) var messages: [ChatMessage] = []

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.sentAt < $1.sentAt }
    }

    var syncStatus: ChatSyncStatus {
        get { ChatSyncStatus(rawValue: syncStatusRawValue ?? "") ?? .local }
        set { syncStatusRawValue = newValue.rawValue }
    }

    var pendingRunStatus: ChatRunStatus? {
        guard let value = remoteStatusRawValue else { return nil }
        return ChatRunStatus(rawValue: value)
    }

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        remoteID: UUID? = nil,
        remoteStatusRawValue: String? = nil,
        syncStatus: ChatSyncStatus = .local,
        pendingRunID: UUID? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remoteID = remoteID
        self.remoteStatusRawValue = remoteStatusRawValue
        self.syncStatusRawValue = syncStatus.rawValue
        self.pendingRunID = pendingRunID
        self.lastSyncedAt = lastSyncedAt
    }
}
