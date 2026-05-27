import Foundation

enum MagicLinkParser {
    static func token(from linkOrToken: String) -> String? {
        let value = linkOrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://"), !value.contains("/") {
            return value
        }

        guard let url = URL(string: value) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }

        if components.count >= 3,
           components[components.count - 3] == "auth",
           components[components.count - 2] == "magic" {
            return components.last
        }

        if components.count >= 2,
           components[components.count - 2] == "magic" {
            return components.last
        }

        if url.host == "magic",
           let token = components.last {
            return token
        }

        return nil
    }
}

enum SignInCodeParser {
    static func normalizedCode(from value: String) -> String? {
        let characters = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        let normalized = String(characters)

        guard normalized.count == 8,
              normalized.range(
                of: #"^[A-Z0-9]{8}$"#,
                options: String.CompareOptions.regularExpression
              ) != nil else {
            return nil
        }

        return String(normalized)
    }

    static func formattedCode(from value: String) -> String? {
        guard let normalized = normalizedCode(from: value) else { return nil }
        let splitIndex = normalized.index(normalized.startIndex, offsetBy: 4)
        return "\(normalized[..<splitIndex])-\(normalized[splitIndex...])"
    }
}
