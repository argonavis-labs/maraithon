import Foundation

@MainActor
protocol AuthProviding {
    func requestMagicLink(email: String) async throws -> MagicLinkRequest
    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser
    /// Returns a locally-stored, still-valid session without any network call, so the
    /// app can sign in instantly on launch and validate with the server in the background.
    func locallyStoredUser() -> AuthenticatedUser?
    func restoreSession() async throws -> AuthenticatedUser?
    func signOut() async throws
    /// Removes any locally persisted session without a network round-trip,
    /// e.g. after the server reports the session unauthorized.
    func clearLocalSession()
}

extension AuthProviding {
    func locallyStoredUser() -> AuthenticatedUser? { nil }
    func clearLocalSession() {}
}
