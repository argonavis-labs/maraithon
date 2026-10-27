/// Shared brief projections identify the people and concrete next moves for one obligation.
import Foundation

enum CompanionTodoWorkspace {
    struct Person: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let relationship: String?
        let context: String?
        let lastInteractionAt: String?
        let verifiedProfile: Bool?
        enum CodingKeys: String, CodingKey {
            case id, name, relationship, context
            case lastInteractionAt = "last_interaction_at", verifiedProfile = "verified_profile"
        }
    }
    struct Action: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let label: String
        let provider: String
        let purpose: String
        let prompt: String
        let personName: String?
        var request: String {
            let target = personName.map { " to \($0)" } ?? ""
            switch provider {
            case "imessage": return "Draft an iMessage\(target) for review. \(purpose)"
            case "gmail": return "Draft an email\(target) for review. \(purpose)"
            case "slack": return "Draft a Slack message\(target) for review. \(purpose)"
            case "browser": return "Use the background Chrome browser on my Mac to help with this step: \(purpose)"
            case "calendar": return "Find time in my calendar and prepare an event for review. \(purpose)"
            default: return "Help me with this next step: \(purpose)"
            }
        }
        enum CodingKeys: String, CodingKey {
            case id, label, provider, purpose, prompt
            case personName = "person_name"
        }
    }
}
