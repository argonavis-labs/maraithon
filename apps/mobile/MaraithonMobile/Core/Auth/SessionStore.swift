import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private let authProvider: AuthProviding

    var phase: SessionPhase = .checking
    var user: AuthenticatedUser?
    var pendingMagicLink: MagicLinkRequest?
    var errorMessage: String?
    var isBusy = false

    init(authProvider: AuthProviding) {
        self.authProvider = authProvider
    }

    func restore() async {
        isBusy = true
        defer { isBusy = false }

        do {
            if let restoredUser = try await authProvider.restoreSession() {
                user = restoredUser
                phase = .signedIn
            } else {
                user = nil
                phase = .signedOut
            }
        } catch {
            errorMessage = error.localizedDescription
            user = nil
            phase = .signedOut
        }
    }

    func requestMagicLink(email: String) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            pendingMagicLink = try await authProvider.requestMagicLink(email: email)
            phase = .magicLinkSent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func consumeMagicLink(_ linkOrToken: String) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            user = try await authProvider.consumeMagicLink(linkOrToken)
            pendingMagicLink = nil
            phase = .signedIn
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleIncomingURL(_ url: URL) async {
        await consumeMagicLink(url.absoluteString)
    }

    func cancelMagicLinkRequest() {
        pendingMagicLink = nil
        errorMessage = nil
        phase = .signedOut
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await authProvider.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }

        user = nil
        pendingMagicLink = nil
        phase = .signedOut
    }
}
