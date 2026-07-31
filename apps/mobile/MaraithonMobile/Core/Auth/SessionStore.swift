import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SessionStore {
    private let authProvider: AuthProviding

    var phase: SessionPhase = .checking
    var user: AuthenticatedUser?
    var pendingMagicLink: MagicLinkRequest?
    var errorMessage: String?
    var isBusy = false

    /// Injected by the app once the SwiftData container exists so sign-out can
    /// wipe the previous user's local data.
    @ObservationIgnored var modelContainer: ModelContainer?

    /// Serializes session mutations (launch restore, magic-link consumption,
    /// sign-out) so a concurrent restore reading stale storage can't overwrite
    /// a just-consumed magic link with signed-out state.
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    init(authProvider: AuthProviding) {
        self.authProvider = authProvider

        // Seed synchronously so a signed-in user's first frame is the shell,
        // not a spinner. restore() still validates with the server.
        if let localUser = authProvider.locallyStoredUser() {
            user = localUser
            phase = .signedIn
        }
    }

    func restore() async {
        await enqueue { await self.performRestore() }
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
        await enqueue { await self.performConsumeMagicLink(linkOrToken) }
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
        await enqueue { await self.performSignOut() }
    }

    /// Any API call answered 401: the session is dead. Clear the stored
    /// credentials (including the Keychain token) and return to sign-in.
    func handleUnauthorized() {
        guard phase != .signedOut else { return }
        authProvider.clearLocalSession()
        user = nil
        pendingMagicLink = nil
        phase = .signedOut
    }

    // MARK: - Serialized operations

    /// Runs `operation` after every previously enqueued session mutation has
    /// finished, so restore/consume/sign-out never interleave.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = sessionTask
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        sessionTask = task
        await task.value
    }

    private func performRestore() async {
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

    private func performConsumeMagicLink(_ linkOrToken: String) async {
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

    private func performSignOut() async {
        isBusy = true
        defer { isBusy = false }

        // Remove this phone's push registration while the session token is
        // still valid — a signed-out phone must not keep receiving another
        // account's notifications.
        await PushCoordinator.shared.unregisterCurrentDevice()

        do {
            try await authProvider.signOut()
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }

        wipeLocalUserData()

        user = nil
        pendingMagicLink = nil
        phase = .signedOut
    }

    /// A signed-out device must not retain the previous user's synced rows,
    /// AI-consent grant, or cached server responses.
    private func wipeLocalUserData() {
        if let modelContainer {
            let context = modelContainer.mainContext
            do {
                for message in try context.fetch(FetchDescriptor<ChatMessage>()) {
                    context.delete(message)
                }
                for thread in try context.fetch(FetchDescriptor<ChatThread>()) {
                    context.delete(thread)
                }
                for todo in try context.fetch(FetchDescriptor<TodoItem>()) {
                    context.delete(todo)
                }
                for contact in try context.fetch(FetchDescriptor<CRMContact>()) {
                    context.delete(contact)
                }
                try context.save()
            } catch {
                // Best effort — the next sign-in reseeds from the server anyway.
            }
        }

        UserDefaults.standard.removeObject(forKey: AuthSessionStorageKeys.aiConsentAccepted)
        URLCache.shared.removeAllCachedResponses()
    }
}
