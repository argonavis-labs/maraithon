/// Shared server-authored brief. Summary stays concise; supporting evidence is optional.
import Foundation

struct CompanionTodoBrief: Codable, Hashable, Sendable {
    let summary: String?
    let involvement: String?
    let situation: String?
    let recommendation: String?
    let doneWhen: String?
    let steps: [String]?
    let openQuestions: [String]?
    let call: Call?
    let people: [CompanionTodoWorkspace.Person]?
    let suggestedActions: [CompanionTodoWorkspace.Action]?

    enum CodingKeys: String, CodingKey {
        case summary, involvement, situation, recommendation, steps, call
        case openQuestions = "open_questions"
        case doneWhen = "done_when"
        case people
        case suggestedActions = "suggested_actions"
    }

    struct Call: Codable, Hashable, Sendable {
        let number: String
        let label: String
        var url: URL? {
            guard number.range(of: #"^\+?[0-9]{7,15}$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "tel:" + number)
        }
    }
}
