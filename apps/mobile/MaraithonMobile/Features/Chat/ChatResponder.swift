import Foundation

enum ChatResponder {
    static func response(
        to message: String,
        openTodoCount: Int,
        contactCount: Int
    ) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return "Send a little more context and I can help turn it into a next action."
        }

        if normalized.contains("todo") || normalized.contains("task") || normalized.contains("follow") {
            let noun = openTodoCount == 1 ? "work item" : "work items"
            return "You have \(openTodoCount) open \(noun). I would capture the next concrete follow-up with a due date and link it to the right person."
        }

        if normalized.contains("crm") || normalized.contains("people") || normalized.contains("person") || normalized.contains("contact") || normalized.contains("relationship") || normalized.contains("deal") {
            return "There are \(contactCount) people in your relationship list. The most useful next step is to update the relationship status, last-contact note, and next follow-up together."
        }

        if normalized.contains("summarize") || normalized.contains("summary") {
            return "Summary: keep the thread focused on one person, one next action, and one follow-up so it can become either a work item or a relationship note."
        }

        return "Captured. Next best action: convert this into a work item, update a relationship note, or keep exploring the conversation here."
    }
}
