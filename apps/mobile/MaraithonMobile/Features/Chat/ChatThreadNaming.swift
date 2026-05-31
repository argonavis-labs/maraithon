import Foundation

enum ChatThreadNaming {
    static let defaultTitle = "New conversation"

    static func title(for firstUserMessage: String, maxLength: Int = 42) -> String {
        let cleaned = normalized(firstUserMessage)

        guard !cleaned.isEmpty else {
            return defaultTitle
        }

        if let suggestedTitle = suggestedTitle(for: cleaned) {
            return suggestedTitle
        }

        return clipped(publicTitleText(cleaned), maxLength: maxLength)
    }

    static func manualTitle(for value: String, maxLength: Int = 64) -> String? {
        let cleaned = normalized(value)
        guard !cleaned.isEmpty else { return nil }
        return clipped(cleaned, maxLength: maxLength)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func suggestedTitle(for value: String) -> String? {
        let lower = value.lowercased()

        if lower.contains("plan my day") || lower.contains("prioritize my day") {
            return "Daily plan"
        }

        if lower.contains("who needs care") ||
            lower.contains("who needs attention") ||
            lower.contains("review my people") ||
            lower.contains("relationship follow") {
            return "Relationship follow-ups"
        }

        if lower.contains("what do i owe") ||
            lower.contains("waiting on me") ||
            lower.contains("waiting on") {
            return "What I owe"
        }

        if lower.contains("draft a follow-up") ||
            lower.contains("draft follow-up") ||
            lower.contains("write a follow-up") {
            return "Follow-up draft"
        }

        if lower.contains("capture work") ||
            lower.contains("capture a work item") ||
            lower.contains("capture a todo") ||
            lower.contains("capture todo") {
            return "Capture work"
        }

        return nil
    }

    private static func publicTitleText(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"(?i)\btodos\b"#, with: "work items", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\btodo\b"#, with: "work item", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^(please\s+|help me\s+|can you\s+|could you\s+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        return capitalizedFirst(cleaned)
    }

    private static func capitalizedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func clipped(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }

        let endIndex = value.index(value.startIndex, offsetBy: maxLength)
        let prefix = String(value[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

        if wordBoundary(in: value, at: endIndex) {
            return prefix
        }

        let trimmedPrefix = prefix
            .split(separator: " ")
            .dropLast()
            .joined(separator: " ")

        return trimmedPrefix.isEmpty ? prefix : trimmedPrefix
    }

    private static func wordBoundary(in value: String, at index: String.Index) -> Bool {
        guard index < value.endIndex else { return true }

        let scalarView = String(value[index]).unicodeScalars
        return scalarView.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) ||
                CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
