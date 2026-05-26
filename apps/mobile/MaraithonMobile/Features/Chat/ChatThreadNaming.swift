import Foundation

enum ChatThreadNaming {
    static func title(for firstUserMessage: String, maxLength: Int = 42) -> String {
        let cleaned = firstUserMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !cleaned.isEmpty else {
            return "New conversation"
        }

        if cleaned.count <= maxLength {
            return cleaned
        }

        let prefix = String(cleaned.prefix(maxLength))
        let trimmedPrefix = prefix
            .split(separator: " ")
            .dropLast()
            .joined(separator: " ")

        return trimmedPrefix.isEmpty ? String(cleaned.prefix(maxLength)) : trimmedPrefix
    }
}
