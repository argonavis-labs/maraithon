import Foundation
import SwiftData

@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var nextAction: String?
    var priorityRawValue: String
    var dueDate: Date?
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    var decisionPrompt: String?
    var decisionContextSummary: String?
    var whyNow: String?
    var sourceContext: String?
    var nextBestAction: String?
    var draftPreview: String?
    var evidenceExcerpt: String?
    var sourceSystem: String?
    var sourceProvider: String?
    var sourceProviderLabel: String?
    var sourceOpenURLString: String?
    var sourceOpenLabel: String?
    var draftText: String?
    var draftKind: String?
    var draftRecipient: String?
    var draftRecipientHandle: String?
    var sourceSubject: String?
    var sourceContextData: Data?
    @Relationship(deleteRule: .nullify, inverse: \CRMContact.todos) var contact: CRMContact?

    var priority: TodoPriority {
        get { TodoPriority(rawValue: priorityRawValue) ?? .medium }
        set { priorityRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        nextAction: String? = nil,
        priority: TodoPriority = .medium,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        decisionPrompt: String? = nil,
        decisionContextSummary: String? = nil,
        whyNow: String? = nil,
        sourceContext: String? = nil,
        nextBestAction: String? = nil,
        draftPreview: String? = nil,
        evidenceExcerpt: String? = nil,
        sourceSystem: String? = nil,
        sourceProvider: String? = nil,
        sourceProviderLabel: String? = nil,
        sourceOpenURLString: String? = nil,
        sourceOpenLabel: String? = nil,
        draftText: String? = nil,
        draftKind: String? = nil,
        draftRecipient: String? = nil,
        draftRecipientHandle: String? = nil,
        sourceSubject: String? = nil,
        sourceContextData: Data? = nil,
        contact: CRMContact? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.nextAction = nextAction
        self.priorityRawValue = priority.rawValue
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.decisionPrompt = decisionPrompt
        self.decisionContextSummary = decisionContextSummary
        self.whyNow = whyNow
        self.sourceContext = sourceContext
        self.nextBestAction = nextBestAction
        self.draftPreview = draftPreview
        self.evidenceExcerpt = evidenceExcerpt
        self.sourceSystem = sourceSystem
        self.sourceProvider = sourceProvider
        self.sourceProviderLabel = sourceProviderLabel
        self.sourceOpenURLString = sourceOpenURLString
        self.sourceOpenLabel = sourceOpenLabel
        self.draftText = draftText
        self.draftKind = draftKind
        self.draftRecipient = draftRecipient
        self.draftRecipientHandle = draftRecipientHandle
        self.sourceSubject = sourceSubject
        self.sourceContextData = sourceContextData
        self.contact = contact
    }

    var sourceAction: TodoSourceAction? {
        let context = storedSourceContext
        let action = TodoSourceAction(
            provider: sourceProvider,
            providerLabel: sourceProviderLabel,
            openURLString: sourceOpenURLString,
            openLabel: sourceOpenLabel,
            draftText: draftText,
            draftKind: draftKind,
            recipient: draftRecipient,
            recipientHandle: draftRecipientHandle,
            subject: sourceSubject,
            participants: context?.participants ?? [],
            conversation: context?.conversation ?? []
        )
        return action.isEmpty ? nil : action
    }

    var storedSourceContext: TodoStoredSourceContext? {
        guard let sourceContextData else { return nil }
        return try? JSONDecoder().decode(TodoStoredSourceContext.self, from: sourceContextData)
    }

    func setSourceContext(participants: [CardParticipant], conversation: [CardConversationMessage]) {
        if participants.isEmpty && conversation.isEmpty {
            sourceContextData = nil
            return
        }

        sourceContextData = try? JSONEncoder().encode(
            TodoStoredSourceContext(participants: participants, conversation: conversation)
        )
    }

    var displayNextAction: String? {
        guard let action = nextAction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !action.isEmpty else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if action.caseInsensitiveCompare(trimmedTitle) == .orderedSame ||
            action.caseInsensitiveCompare(trimmedNotes) == .orderedSame {
            return nil
        }

        return action
    }

    func setCompleted(_ completed: Bool, at date: Date = Date()) {
        isCompleted = completed
        completedAt = completed ? date : nil
    }
}

/// Codable bundle persisted on TodoItem for participants + conversation.
struct TodoStoredSourceContext: Codable, Equatable, Sendable {
    var participants: [CardParticipant] = []
    var conversation: [CardConversationMessage] = []
}
