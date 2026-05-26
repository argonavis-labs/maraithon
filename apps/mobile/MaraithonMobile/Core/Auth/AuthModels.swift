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

enum AuthEntryMode: String, CaseIterable, Identifiable {
    case signIn
    case signUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signIn: "Sign In"
        case .signUp: "Sign Up"
        }
    }

    var actionTitle: String {
        switch self {
        case .signIn, .signUp: "Email Me a Link"
        }
    }
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
            "Request a new sign-in link."
        case .invalidOrExpiredLink:
            "Sign-in link is invalid or expired."
        case .restoreFailed:
            "The saved session could not be restored."
        }
    }
}
