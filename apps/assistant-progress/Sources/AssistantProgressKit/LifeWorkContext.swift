/// Shared life/work review contracts. Proposals stay separate from user-confirmed details.
import Foundation

public enum LifeWorkContext {
    public typealias Request = @MainActor (String, Input?) async throws -> Response

    public struct Response: Decodable, Sendable {
        public let notes: [Note]?
        public let note: Note?
        public let person: Person?
    }

    public struct Note: Decodable, Identifiable, Sendable {
        public let id: String
        public let text: String
        public let state: String
        public let domain: String
        public let summary: String?
        public let rules: [String]
        public let people: [Proposal]
        public let confirmedAt: String?
        enum CodingKeys: String, CodingKey {
            case id, text, state, domain, summary, rules, people
            case confirmedAt = "confirmed_at"
        }
    }

    public struct Proposal: Decodable, Identifiable, Sendable {
        public var id: Int { index }
        public let index: Int
        public let name: String
        public let relationship: String?
        public let confirmedAt: String?
        enum CodingKeys: String, CodingKey {
            case index, name, relationship
            case confirmedAt = "confirmed_at"
        }
    }

    public struct Person: Decodable, Sendable {
        public let id: String?
        public let name: String
        public let relationship: String?
        public let notes: String?
        public let emails: [String]
        public let phones: [String]
        public let confirmedAt: String?
        public let suggestedRelationship: String?
        public let suggestedNotes: String?
        enum CodingKeys: String, CodingKey {
            case id, name, relationship, notes, emails, phones
            case confirmedAt = "confirmed_at"
            case suggestedRelationship = "suggested_relationship"
            case suggestedNotes = "suggested_notes"
        }
    }

    public struct PersonReference: Identifiable, Sendable {
        public let fields: [String: String]
        public var id: String { fields.keys.sorted().map { "\($0):\(fields[$0] ?? "")" }.joined(separator: "|") }
        public init(personID: String) { fields = ["person_id": personID] }
        public init(todoID: String, reference: String) { fields = ["todo_id": todoID, "reference": reference] }
        public init(noteID: String, index: Int) { fields = ["note_id": noteID, "index": String(index)] }
        public var path: String {
            var url = URLComponents()
            url.path = "person-review"
            url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return url.string ?? "person-review"
        }
    }

    public struct Details: Encodable, Sendable {
        var name: String
        var relationship: String
        var notes: String
        var emails: String
        var phones: String
    }

    public struct Input: Encodable, Sendable {
        var text: String?
        var domain: String?
        var inputMode: String?
        var requestID: String?
        var summary: String?
        var rules: [String]?
        var personID: String?
        var todoID: String?
        var reference: String?
        var noteID: String?
        var index: String?
        var details: Details?
        enum CodingKeys: String, CodingKey {
            case text, domain, summary, rules, reference, index, details
            case inputMode = "input_mode", requestID = "request_id", personID = "person_id"
            case todoID = "todo_id", noteID = "note_id"
        }
        static func confirmation(_ reference: PersonReference, details: Details, requestID: String) -> Self {
            Self(requestID: requestID, personID: reference.fields["person_id"], todoID: reference.fields["todo_id"],
                 reference: reference.fields["reference"], noteID: reference.fields["note_id"],
                 index: reference.fields["index"], details: details)
        }
    }
}
