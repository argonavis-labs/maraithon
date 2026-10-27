import Foundation

struct AuthenticatedUser: Codable, Equatable, Identifiable {
    let id: String
    let email: String
    let signedInAt: Date
    let sessionExpiresAt: Date
    let sessionToken: String?
}

struct MagicLinkRequest: Codable, Equatable, Identifiable {
    let id: String
    let email: String
    let expiresAt: Date
    let developmentLink: String?
    let developmentToken: String?
    let developmentCode: String?

    var isExpired: Bool {
        expiresAt <= Date()
    }
}

enum SessionPhase: Equatable {
    case checking
    case signedOut
    case magicLinkSent
    case signedIn
}

enum AuthError: LocalizedError, Equatable {
    case invalidEmail
    case magicLinkNotFound
    case invalidOrExpiredLink
    case restoreFailed

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            "Please enter a valid email address."
        case .magicLinkNotFound:
            "Request a new sign-in code."
        case .invalidOrExpiredLink:
            "Sign-in code is invalid or expired."
        case .restoreFailed:
            "Sign-in could not be restored. Sign in again."
        }
    }
}
