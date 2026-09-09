/// The bounded server projection shared by both native clients.
/// IDs remain opaque strings because observed people need not be CRM records.
import Foundation

public enum PeopleNetworkData {
    public struct Network: Decodable, Sendable {
        public let status: String
        public let nodes: [Person]
        public let edges: [Edge]
        public let meetings: [Meeting]
        public let peopleCount: Int
        public let refreshedAt: String?
        public let warnings: [String]?
        enum CodingKeys: String, CodingKey {
            case status, nodes, edges, meetings, warnings
            case peopleCount = "people_count", refreshedAt = "refreshed_at"
        }
    }

    public struct PersonResponse: Decodable, Sendable {
        public let person: Person
    }

    public struct Person: Decodable, Identifiable, Sendable {
        public let id: String
        public let personID: String?
        public let name: String
        public let subtitle: String?
        public let rank: Double
        public let activeDays: Int
        public let messageCount: Int
        public let lastAt: String?
        public let x: Double
        public let y: Double
        public let channels: [Channel]
        public let history: [Evidence]?
        public let nextMeetings: [Meeting]?
        public let connections: [Connection]?
        public let todos: [Todo]?
        public let notes: String?

        public var initials: String {
            name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        }
        enum CodingKeys: String, CodingKey {
            case id, name, subtitle, rank, x, y, channels, history, connections, todos, notes
            case personID = "person_id", activeDays = "active_days", messageCount = "message_count"
            case lastAt = "last_at", nextMeetings = "next_meetings"
        }
    }

    public struct Channel: Decodable, Sendable {
        public let source: String
        public let count: Int
    }

    public struct Edge: Decodable, Identifiable, Sendable {
        public let id: String
        public let from: String
        public let to: String
        public let kind: String
        public let weight: Double
        public let evidence: [Evidence]
    }

    public struct Connection: Decodable, Identifiable, Sendable {
        public let nodeID: String
        public let name: String
        public let evidence: [Evidence]
        public var id: String { nodeID }
        enum CodingKeys: String, CodingKey {
            case name, evidence
            case nodeID = "node_id"
        }
    }

    public struct Evidence: Decodable, Identifiable, Sendable {
        public let id: String
        public let type: String
        public let title: String?
        public let at: String
        public let source: String
        public let kind: String?
        public let direction: String?
        public let excerpt: String?
    }

    public struct Meeting: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let at: String
        public let people: [Attendee]?
    }

    public struct Attendee: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Todo: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let nextAction: String?
        enum CodingKeys: String, CodingKey {
            case id, title
            case nextAction = "next_action"
        }
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "gmail": "Email"
        case "slack": "Slack"
        case "whatsapp": "WhatsApp"
        case "calendar": "Calendar"
        default: "Messages"
        }
    }
}
