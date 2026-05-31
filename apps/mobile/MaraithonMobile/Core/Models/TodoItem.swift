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
    var evidenceExcerpt: String?
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
        evidenceExcerpt: String? = nil,
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
        self.evidenceExcerpt = evidenceExcerpt
        self.contact = contact
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
