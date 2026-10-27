import Foundation

enum EmailValidator {
    static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ email: String) -> Bool {
        let value = normalized(email)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        guard let local = parts.first, let domain = parts.last else { return false }
        guard !local.isEmpty, !domain.isEmpty, domain.contains(".") else { return false }
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return domain.split(separator: ".").allSatisfy { !$0.isEmpty }
    }
}
