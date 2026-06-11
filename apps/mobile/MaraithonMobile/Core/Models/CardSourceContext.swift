import Foundation

/// One person attached to a next-action card, preserving their channel role
/// (from, to, cc, bcc) so the card can show everyone involved.
struct CardParticipant: Codable, Hashable, Sendable {
    var role: String?
    var name: String?
    var handle: String?

    init(role: String? = nil, name: String? = nil, handle: String? = nil) {
        self.role = role
        self.name = name
        self.handle = handle
    }

    init?(_ value: JSONValue?) {
        guard let object = value?.object else { return nil }
        role = object["role"]?.string
        name = object["name"]?.string
        handle = object["handle"]?.string
        if displayName.isEmpty { return nil }
    }

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        return handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var roleLabel: String? {
        switch role {
        case "from": "From"
        case "to": "To"
        case "cc": "Cc"
        case "bcc": "Bcc"
        default: nil
        }
    }

    /// "Dana Chen (dana@acme.com)" when both are known and distinct.
    var detailedLabel: String {
        let name = displayName
        guard let handle, !handle.isEmpty, handle.caseInsensitiveCompare(name) != .orderedSame else {
            return name
        }
        return "\(name) (\(handle))"
    }
}

/// One line of the source conversation shown on a card for context.
struct CardConversationMessage: Codable, Hashable, Sendable {
    var speaker: String?
    var text: String
    var at: String?
    var fromUser: Bool?

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
        case at
        case fromUser = "from_user"
    }

    init(speaker: String? = nil, text: String, at: String? = nil, fromUser: Bool? = nil) {
        self.speaker = speaker
        self.text = text
        self.at = at
        self.fromUser = fromUser
    }

    init?(_ value: JSONValue?) {
        guard let object = value?.object,
              let text = object["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }

        self.text = text
        speaker = object["speaker"]?.string
        at = object["at"]?.string
        if case .bool(let flag) = object["from_user"] ?? .null {
            fromUser = flag
        }
    }

    var speakerLabel: String {
        if fromUser == true { return "You" }
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Them" : trimmed
    }
}

enum CardSourceContextParsing {
    static func participants(_ value: JSONValue?) -> [CardParticipant] {
        (value?.array ?? []).compactMap { CardParticipant($0) }
    }

    static func conversation(_ value: JSONValue?) -> [CardConversationMessage] {
        (value?.array ?? []).compactMap { CardConversationMessage($0) }
    }
}
