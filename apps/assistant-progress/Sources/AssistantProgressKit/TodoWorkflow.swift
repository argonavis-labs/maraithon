import Foundation

/// The server owns transitions. Clients display and submit one versioned handoff.
public struct TodoWorkflow: Codable, Hashable, Sendable {
    public let state: String
    public let label: String
    public let owner: Owner
    public let outcome: String
    public let nextAction: String?
    public let reason: String?
    public let revision: Int
    public let waitingUntil: String?
    public let changedAt: String?

    public struct Owner: Codable, Hashable, Identifiable, Sendable {
        public let kind: String
        public let id: String
        public let label: String
        public var displayName: String { kind == "user" ? "You" : label }
        public var selectionID: String { kind == "user" ? "user" : "person:" + id }
        public init(kind: String, id: String, label: String) {
            self.kind = kind; self.id = id; self.label = label
        }
    }
    public var ballLabel: String {
        if ["done", "cancelled"].contains(state) { return "Owner: " + owner.displayName }
        if state == "waiting" {
            return owner.kind == "user" ? "You own follow-up" : owner.displayName + " owns follow-up"
        }
        return owner.kind == "user" ? "Your move" : owner.displayName + "’s move"
    }
    public static let states = ["you_own", "working", "waiting", "they_own", "cancelled", "done"]
    public static func label(for state: String) -> String {
        ["you_own": "You own the action", "working": "Working", "waiting": "Waiting",
         "they_own": "They own the action", "cancelled": "Cancelled", "done": "Done"][state] ?? state
    }
    enum CodingKeys: String, CodingKey {
        case state, label, owner, outcome, reason, revision
        case nextAction = "next_action", waitingUntil = "waiting_until", changedAt = "changed_at"
    }
}

public struct TodoWorkflowChange: Encodable, Equatable, Sendable {
    public let state: String
    public let owner: TodoWorkflow.Owner
    public let outcome: String
    public let nextAction: String
    public let reason: String
    public let expectedRevision: Int
    public let outcomeConfirmed: Bool
    public let requestID: String
    public let waitingUntil: String
    enum CodingKeys: String, CodingKey {
        case state, owner, outcome, reason
        case nextAction = "next_action", expectedRevision = "expected_revision"
        case outcomeConfirmed = "outcome_confirmed", requestID = "request_id", waitingUntil = "waiting_until"
    }
    public init(state: String, owner: TodoWorkflow.Owner, outcome: String, nextAction: String,
                reason: String, expectedRevision: Int, requestID: String, waitingUntil: String = "") {
        self.state = state; self.owner = owner; self.outcome = outcome; self.nextAction = nextAction
        self.reason = reason; self.expectedRevision = expectedRevision; self.outcomeConfirmed = state == "done"
        self.requestID = requestID
        self.waitingUntil = waitingUntil
    }
}
