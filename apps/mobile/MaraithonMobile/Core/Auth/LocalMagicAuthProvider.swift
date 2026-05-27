import Foundation

@MainActor
final class LocalMagicAuthProvider: AuthProviding {
    private struct PendingMagicLink {
        let email: String
        let token: String
        let code: String
        let expiresAt: Date
    }

    private enum Constants {
        static let magicLinkLifetime: TimeInterval = 15 * 60
        static let sessionLifetime: TimeInterval = 60 * 24 * 60 * 60
    }

    private var pendingLinks: [String: PendingMagicLink] = [:]
    private var pendingCodes: [String: PendingMagicLink] = [:]
    private let userDefaults: UserDefaults
    private let tokenGenerator: () -> String
    private let codeGenerator: () -> String
    private let magicLinkBaseURL: URL
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        tokenGenerator: @escaping () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        },
        codeGenerator: @escaping () -> String = LocalMagicAuthProvider.generateCode,
        magicLinkBaseURL: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.tokenGenerator = tokenGenerator
        self.codeGenerator = codeGenerator
        self.magicLinkBaseURL = magicLinkBaseURL
        self.now = now
    }

    func requestMagicLink(email: String) async throws -> MagicLinkRequest {
        let normalizedEmail = EmailValidator.normalized(email)
        guard EmailValidator.isValid(normalizedEmail) else {
            throw AuthError.invalidEmail
        }

        let token = tokenGenerator()
        let code = Self.normalizedCode(from: codeGenerator())
        let expiresAt = now().addingTimeInterval(Constants.magicLinkLifetime)
        let pendingLink = PendingMagicLink(
            email: normalizedEmail,
            token: token,
            code: code,
            expiresAt: expiresAt
        )
        pendingLinks[token] = pendingLink
        pendingCodes[code] = pendingLink

        return MagicLinkRequest(
            id: token,
            email: normalizedEmail,
            expiresAt: expiresAt,
            developmentLink: magicLinkURL(for: token).absoluteString,
            developmentToken: token,
            developmentCode: SignInCodeParser.formattedCode(from: code)
        )
    }

    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser {
        guard let link = pendingLink(for: linkOrToken) else {
            throw AuthError.invalidOrExpiredLink
        }

        guard link.expiresAt > now() else {
            removePendingLink(link)
            throw AuthError.invalidOrExpiredLink
        }

        removePendingLink(link)

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
        pendingCodes.removeAll()
        userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
    }

    private func persist(_ user: AuthenticatedUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        userDefaults.set(data, forKey: AuthSessionStorageKeys.authenticatedUser)
    }

    private func magicLinkURL(for token: String) -> URL {
        magicLinkBaseURL.appendingPathComponent(token)
    }

    private func pendingLink(for value: String) -> PendingMagicLink? {
        if let code = SignInCodeParser.normalizedCode(from: value),
           let link = pendingCodes[code] {
            return link
        }

        guard let token = MagicLinkParser.token(from: value) else {
            return nil
        }

        return pendingLinks[token]
    }

    private func removePendingLink(_ link: PendingMagicLink) {
        pendingLinks[link.token] = nil
        pendingCodes[link.code] = nil
    }

    nonisolated private static func normalizedCode(from value: String) -> String {
        SignInCodeParser.normalizedCode(from: value) ?? generateCode()
    }

    nonisolated private static func generateCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return String((0..<8).compactMap { _ in alphabet.randomElement() })
    }
}
