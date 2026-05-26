import Foundation

@MainActor
final class ProductionMagicAuthProvider: AuthProviding {
    private let apiClient: MobileAPIClient
    private let userDefaults: UserDefaults
    private let now: () -> Date

    init(
        apiClient: MobileAPIClient = MobileAPIClient(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.apiClient = apiClient
        self.userDefaults = userDefaults
        self.now = now
    }

    func requestMagicLink(email: String) async throws -> MagicLinkRequest {
        let normalizedEmail = EmailValidator.normalized(email)
        guard EmailValidator.isValid(normalizedEmail) else {
            throw AuthError.invalidEmail
        }

        let response = try await apiClient.requestMagicLink(email: normalizedEmail)
        return MagicLinkRequest(
            id: response.magicLink.email,
            email: response.magicLink.email,
            expiresAt: now().addingTimeInterval(response.magicLink.expiresInSeconds),
            developmentLink: nil,
            developmentToken: nil
        )
    }

    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser {
        guard let token = MagicLinkParser.token(from: linkOrToken) else {
            throw AuthError.invalidOrExpiredLink
        }

        let response = try await apiClient.consumeMagicLink(token: token)
        let user = authenticatedUser(from: response)
        persist(user)
        return user
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        guard let data = userDefaults.data(forKey: AuthSessionStorageKeys.authenticatedUser) else {
            return nil
        }

        let savedUser: AuthenticatedUser
        do {
            savedUser = try JSONDecoder().decode(AuthenticatedUser.self, from: data)
        } catch {
            userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
            throw AuthError.restoreFailed
        }

        guard savedUser.sessionExpiresAt > now(),
              let sessionToken = savedUser.sessionToken else {
            userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
            return nil
        }

        let response = try await apiClient.me(sessionToken: sessionToken)
        let restored = AuthenticatedUser(
            id: response.user.id,
            email: response.user.email,
            signedInAt: savedUser.signedInAt,
            sessionExpiresAt: response.user.sessionExpiresAt,
            sessionToken: sessionToken
        )
        persist(restored)
        return restored
    }

    func signOut() async throws {
        if let data = userDefaults.data(forKey: AuthSessionStorageKeys.authenticatedUser),
           let user = try? JSONDecoder().decode(AuthenticatedUser.self, from: data),
           let sessionToken = user.sessionToken {
            try? await apiClient.signOut(sessionToken: sessionToken)
        }

        userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
    }

    private func authenticatedUser(from response: MobileAPIClient.AuthResponse) -> AuthenticatedUser {
        AuthenticatedUser(
            id: response.user.id,
            email: response.user.email,
            signedInAt: now(),
            sessionExpiresAt: response.user.sessionExpiresAt,
            sessionToken: response.sessionToken
        )
    }

    private func persist(_ user: AuthenticatedUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        userDefaults.set(data, forKey: AuthSessionStorageKeys.authenticatedUser)
    }
}
