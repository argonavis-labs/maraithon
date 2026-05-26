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
