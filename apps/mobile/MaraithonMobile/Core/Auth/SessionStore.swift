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

        // Local-first: if a valid session is stored, show the app immediately and
        // validate with the server in the background — launch never waits on the network.
        let localUser = authProvider.locallyStoredUser()
        if let localUser {
            user = localUser
            phase = .signedIn
        }

        do {
            if let restoredUser = try await authProvider.restoreSession() {
                user = restoredUser
                phase = .signedIn
            } else {
                user = nil
                phase = .signedOut
            }
        } catch MobileAPIError.unauthorized {
            // Session is genuinely invalid — sign out even if we showed it optimistically.
            user = nil
            phase = .signedOut
        } catch {
            // Background validation failed (offline/transient). Keep the optimistic
            // session if we had one; only surface an error when we had nothing local.
            if localUser == nil {
                errorMessage = MobileErrorCopy.message(for: error)
                user = nil
                phase = .signedOut
            }
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
            errorMessage = MobileErrorCopy.message(for: error)
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
            errorMessage = MobileErrorCopy.message(for: error)
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
            errorMessage = MobileErrorCopy.message(for: error)
        }

        user = nil
        pendingMagicLink = nil
        phase = .signedOut
    }
}
