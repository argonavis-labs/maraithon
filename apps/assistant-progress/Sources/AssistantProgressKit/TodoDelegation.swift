import Foundation

/// The server owns conversation authority, revisions and available controls.
public struct TodoDelegation: Codable, Hashable, Sendable {
    public let id: String
    public let state: String
    public let revision: Int
    public let statusLine: String
    public let actorLabel: String
    public let lastAction: String?
    public let nextFollowUp: String?
    public let question: String?
    public let holdReason: String?
    public let controls: [String]

    enum CodingKeys: String, CodingKey {
        case id, state, revision, question, controls
        case statusLine = "status_line", actorLabel = "actor_label"
        case lastAction = "last_action", nextFollowUp = "next_follow_up", holdReason = "hold_reason"
    }

    public var isTerminal: Bool { ["completed", "stopped", "expired"].contains(state) }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    public struct Response: Decodable, Sendable {
        public let delegation: TodoDelegation?
        public let scope: Scope?
    }

    public struct Scope: Decodable, Sendable {
        public let provider: String
        public let actor: String
        public let kind: String
        public let outcome: String
        public let to: [String]
        public let cc: [String]
        public let firstSendCc: [String]?
        public let scopeHash: String
        public let workflowRevision: Int
        public let identity: Identity
        public let taskOwner: Owner

        public struct Identity: Decodable, Sendable {
            public let email: String?
            public let displayName: String?
            enum CodingKeys: String, CodingKey { case email; case displayName = "display_name" }
        }
        public struct Owner: Decodable, Sendable {
            public let kind: String
            public let label: String?
            public let name: String?
            public var title: String { label ?? name ?? (kind == "user" ? "You" : "Someone else") }
        }
        enum CodingKeys: String, CodingKey {
            case provider, actor, kind, outcome, to, cc, identity
            case scopeHash = "scope_hash", workflowRevision = "workflow_revision", taskOwner = "task_owner"
            case firstSendCc = "first_send_cc"
        }
    }

    /// A retry retains its request ID and expected revision. The server rejects stale authority.
    public struct Request: Encodable, Equatable, Sendable {
        public var actor: String?
        public var kind: String?
        public var outcome: String?
        public var instruction: String?
        public var to: [String]?
        public var cc: [String]?
        public var scopeHash: String?
        public var expectedRevision: Int?
        public var requestID: String = UUID().uuidString
        public var answer: String?
        public init() {}
        enum CodingKeys: String, CodingKey {
            case actor, kind, outcome, instruction, to, cc, answer
            case scopeHash = "scope_hash", expectedRevision = "expected_revision", requestID = "request_id"
        }
    }
}
