import Foundation

@MainActor
protocol AuthProviding {
    func requestMagicLink(email: String) async throws -> MagicLinkRequest
    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser
    func restoreSession() async throws -> AuthenticatedUser?
    func signOut() async throws
}
