import Foundation

@MainActor
final class LocalMagicAuthProvider: AuthProviding {
    private struct PendingMagicLink {
        let email: String
        let token: String
        let expiresAt: Date
    }

    private enum Constants {
        static let magicLinkLifetime: TimeInterval = 15 * 60
        static let sessionLifetime: TimeInterval = 60 * 24 * 60 * 60
    }

    private var pendingLinks: [String: PendingMagicLink] = [:]
    private let userDefaults: UserDefaults
    private let tokenGenerator: () -> String
    private let magicLinkBaseURL: URL
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        tokenGenerator: @escaping () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        },
        magicLinkBaseURL: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.tokenGenerator = tokenGenerator
        self.magicLinkBaseURL = magicLinkBaseURL
        self.now = now
    }

    func requestMagicLink(email: String) async throws -> MagicLinkRequest {
        let normalizedEmail = EmailValidator.normalized(email)
        guard EmailValidator.isValid(normalizedEmail) else {
            throw AuthError.invalidEmail
        }

        let token = tokenGenerator()
        let expiresAt = now().addingTimeInterval(Constants.magicLinkLifetime)
        pendingLinks[token] = PendingMagicLink(
            email: normalizedEmail,
            token: token,
            expiresAt: expiresAt
        )

        return MagicLinkRequest(
            id: token,
            email: normalizedEmail,
            expiresAt: expiresAt,
            developmentLink: magicLinkURL(for: token).absoluteString,
            developmentToken: token
        )
    }

    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser {
        guard let token = MagicLinkParser.token(from: linkOrToken),
              let link = pendingLinks[token] else {
            throw AuthError.invalidOrExpiredLink
        }

        guard link.expiresAt > now() else {
            pendingLinks[token] = nil
            throw AuthError.invalidOrExpiredLink
        }

        pendingLinks[token] = nil

        let user = AuthenticatedUser(
            id: link.email,
            email: link.email,
            signedInAt: now(),
            sessionExpiresAt: now().addingTimeInterval(Constants.sessionLifetime),
            sessionToken: nil
        )
        persist(user)
        return user
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        guard let data = userDefaults.data(forKey: AuthSessionStorageKeys.authenticatedUser) else {
            return nil
        }

        do {
            let user = try JSONDecoder().decode(AuthenticatedUser.self, from: data)
            guard user.sessionExpiresAt > now() else {
                userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
                return nil
            }
            return user
        } catch {
            userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
            throw AuthError.restoreFailed
        }
    }

    func signOut() async throws {
        pendingLinks.removeAll()
        userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
    }

    private func persist(_ user: AuthenticatedUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        userDefaults.set(data, forKey: AuthSessionStorageKeys.authenticatedUser)
    }

    private func magicLinkURL(for token: String) -> URL {
        magicLinkBaseURL.appendingPathComponent(token)
    }
}
