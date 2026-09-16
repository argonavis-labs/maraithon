import Foundation

/// Bounded pages of saved conversation evidence, interpreted by the server.
public struct TodoDelegationHistory: Decodable, Sendable {
    public let entries: [Entry]
    public let nextBefore: String?
    public let outcome: String?
    public let evidence: [SourceLink]
    public let facts: [Fact]

    enum CodingKeys: String, CodingKey {
        case entries, outcome, evidence, facts
        case nextBefore = "next_before"
    }

    public struct Entry: Decodable, Identifiable, Sendable {
        public let id: String
        public let occurredAt: String
        public let title: String
        public let detail: String?
        public let links: [SourceLink]
        enum CodingKeys: String, CodingKey {
            case id, title, detail, links
            case occurredAt = "occurred_at"
        }
    }

    public struct Fact: Decodable, Identifiable, Sendable {
        public let id: String
        public let text: String
        public let recordedAt: String?
        public let links: [SourceLink]
        enum CodingKeys: String, CodingKey {
            case id, text, links
            case recordedAt = "recorded_at"
        }
    }

    public struct SourceLink: Decodable, Hashable, Sendable {
        public let label: String
        public let url: String
    }
}
