import Foundation
import SwiftData

@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var priorityRawValue: String
    var dueDate: Date?
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    @Relationship(deleteRule: .nullify, inverse: \CRMContact.todos) var contact: CRMContact?

    var priority: TodoPriority {
        get { TodoPriority(rawValue: priorityRawValue) ?? .medium }
        set { priorityRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        priority: TodoPriority = .medium,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        contact: CRMContact? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priorityRawValue = priority.rawValue
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.contact = contact
    }

    func setCompleted(_ completed: Bool, at date: Date = Date()) {
        isCompleted = completed
        completedAt = completed ? date : nil
    }
}
