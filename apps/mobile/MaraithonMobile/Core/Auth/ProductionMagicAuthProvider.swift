import Foundation

@MainActor
final class ProductionMagicAuthProvider: AuthProviding {
    private let apiClient: MobileAPIClient
    private let userDefaults: UserDefaults
    private let tokenStore: SessionTokenStoring
    private let now: () -> Date

    init(
        apiClient: MobileAPIClient = MobileAPIClient(),
        userDefaults: UserDefaults = .standard,
        tokenStore: SessionTokenStoring = KeychainTokenStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.apiClient = apiClient
        self.userDefaults = userDefaults
        self.tokenStore = tokenStore
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
            developmentToken: nil,
            developmentCode: nil
        )
    }

    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser {
        let response: MobileAPIClient.AuthResponse

        if let code = SignInCodeParser.normalizedCode(from: linkOrToken) {
            response = try await apiClient.consumeMagicCode(code: code)
        } else if let token = MagicLinkParser.token(from: linkOrToken) {
            response = try await apiClient.consumeMagicLink(token: token)
        } else {
            throw AuthError.invalidOrExpiredLink
        }

        let user = authenticatedUser(from: response)
        persist(user)
        return user
    }

    func locallyStoredUser() -> AuthenticatedUser? {
        guard let savedUser = (try? loadStoredUser()) ?? nil,
              savedUser.sessionExpiresAt > now(),
              savedUser.sessionToken != nil else {
            return nil
        }
        return savedUser
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        guard let savedUser = try loadStoredUser() else {
            return nil
        }

        guard savedUser.sessionExpiresAt > now(),
              let sessionToken = savedUser.sessionToken else {
            clearLocalSession()
            return nil
        }

        let response: MobileAPIClient.MeResponse
        do {
            response = try await apiClient.me(sessionToken: sessionToken)
        } catch MobileAPIError.unauthorized {
            // The session is genuinely invalid; drop it so we don't keep retrying it.
            clearLocalSession()
            throw MobileAPIError.unauthorized
        }
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
        if let user = (try? loadStoredUser()) ?? nil,
           let sessionToken = user.sessionToken {
            try? await apiClient.signOut(sessionToken: sessionToken)
        }

        clearLocalSession()
    }

    func clearLocalSession() {
        userDefaults.removeObject(forKey: AuthSessionStorageKeys.authenticatedUser)
        tokenStore.delete()
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

    /// Decodes the stored profile and reattaches the session token from the
    /// Keychain. Sessions saved before the Keychain move still carry the token
    /// inside the UserDefaults blob; migrate it into the Keychain and rewrite
    /// the blob without the secret.
    private func loadStoredUser() throws -> AuthenticatedUser? {
        guard let data = userDefaults.data(forKey: AuthSessionStorageKeys.authenticatedUser) else {
            return nil
        }

        let savedUser: AuthenticatedUser
        do {
            savedUser = try JSONDecoder().decode(AuthenticatedUser.self, from: data)
        } catch {
            clearLocalSession()
            throw AuthError.restoreFailed
        }

        let user = AuthenticatedUser(
            id: savedUser.id,
            email: savedUser.email,
            signedInAt: savedUser.signedInAt,
            sessionExpiresAt: savedUser.sessionExpiresAt,
            sessionToken: tokenStore.get() ?? savedUser.sessionToken
        )

        if savedUser.sessionToken != nil {
            // Legacy blob still holds the secret — persist moves it to the Keychain.
            persist(user)
        }
        return user
    }

    /// Splits persistence: the secret session token goes to the Keychain, the
    /// non-secret profile (id/email/expiry) stays in UserDefaults.
    private func persist(_ user: AuthenticatedUser) {
        if let token = user.sessionToken {
            tokenStore.set(token)
        } else {
            tokenStore.delete()
        }

        let profile = AuthenticatedUser(
            id: user.id,
            email: user.email,
            signedInAt: user.signedInAt,
            sessionExpiresAt: user.sessionExpiresAt,
            sessionToken: nil
        )
        guard let data = try? JSONEncoder().encode(profile) else { return }
        userDefaults.set(data, forKey: AuthSessionStorageKeys.authenticatedUser)
    }
}
