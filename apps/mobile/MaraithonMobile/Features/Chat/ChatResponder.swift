import Foundation

enum ChatResponder {
    static func response(
        to message: String,
        openTodoCount: Int,
        contactCount: Int
    ) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return "Add the thread, person, and desired outcome. Maraithon will turn it into a next action, draft, or relationship note."
        }

        if normalized.contains("todo") || normalized.contains("task") || normalized.contains("follow") {
            let noun = openTodoCount == 1 ? "work item" : "work items"
            return "You have \(openTodoCount) open \(noun). Next move: capture the owner, due date, and exact follow-up, then link it to the right person."
        }

        if normalized.contains("crm") || normalized.contains("people") || normalized.contains("person") || normalized.contains("contact") || normalized.contains("relationship") || normalized.contains("deal") {
            return "\(contactCount) people are in relationship context. Next move: update status, last-contact evidence, and the next follow-up together."
        }

        if normalized.contains("summarize") || normalized.contains("summary") {
            return "Summary frame: one person, one obligation, one next move. Keep only the detail needed to create a work item, draft, or relationship note."
        }

        return "Captured. Next best action: decide whether this is a work item, relationship note, or draft. Add owner and timing if it should stay visible."
    }
}
