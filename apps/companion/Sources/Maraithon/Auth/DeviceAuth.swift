import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Authentication state machine for the companion device. Owns the
/// pair/sign-in/sign-out flow and exposes the bearer token to other
/// services through `currentToken`. The token never leaves Keychain
/// except via this type.
///
/// The state machine deliberately keeps a single source of truth — the
/// `state` property — and emits a structured `EventLog` entry on every
/// transition. The Keychain wrapper and HTTP client are injected so tests
/// can drive the full flow without touching the system.
@Observable
@MainActor
final class DeviceAuth {
    enum State: Equatable {
        case signedOut
        case connecting
        case awaitingApproval(deviceId: UUID)
        case signedIn(account: Account)
        case error(message: String)
    }

    struct Account: Equatable, Codable, Sendable {
        let email: String
        let deviceName: String

        enum CodingKeys: String, CodingKey {
            case email
            case deviceName = "device_name"
        }
    }

    /// Resolves the `MaraithonClient` used for `whoami` after a successful
    /// pair. The closure form lets us inject a mock in tests and lets the
    /// real wiring use the same token-provider closure the engine uses.
    typealias ClientFactory = @MainActor @Sendable (DeviceAuth) -> MaraithonClient

    /// Hook for opening the pairing URL. Real impl uses `NSWorkspace`; the
    /// test impl records the URL so we can assert on it.
    typealias URLOpener = @MainActor @Sendable (URL) -> Void

    private(set) var state: State = .signedOut

    /// Stable UUID for this Mac. Persisted to UserDefaults so the same
    /// install survives Keychain wipes (e.g. user signs out and back in)
    /// without registering a brand-new device.
    private(set) var deviceId: UUID

    private let eventLog: EventLog
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let clientFactory: ClientFactory
    private let urlOpener: URLOpener
    private let authBaseURL: URL
    private let deviceName: String

    /// UserDefaults key for the persisted `device_id`.
    private static let defaultsKey = "com.maraithon.companion.device_id"

    init(
        eventLog: EventLog,
        keychain: KeychainStore = defaultKeychainStore(),
        defaults: UserDefaults = .standard,
        authBaseURL: URL = DeviceAuth.defaultBaseURL(),
        deviceName: String = DeviceAuth.defaultDeviceName(),
        clientFactory: @escaping ClientFactory = DeviceAuth.defaultClientFactory,
        urlOpener: @escaping URLOpener = DeviceAuth.defaultURLOpener
    ) {
        self.eventLog = eventLog
        self.keychain = keychain
        self.defaults = defaults
        self.authBaseURL = authBaseURL
        self.deviceName = deviceName
        self.clientFactory = clientFactory
        self.urlOpener = urlOpener
        self.deviceId = DeviceAuth.loadOrCreateDeviceId(defaults: defaults)
        eventLog.debug(
            "device_auth.init",
            source: .auth,
            payload: ["device_id": self.deviceId.uuidString]
        )
        hydrateFromKeychain()
    }

    /// On launch, if Keychain holds a token, validate it via `whoami` and
    /// transition to `.signedIn` so the user doesn't have to re-pair every
    /// session. Invalid/revoked tokens get cleared and the user is shown
    /// `.signedOut`.
    private func hydrateFromKeychain() {
        guard let token = currentToken, !token.isEmpty else { return }
        eventLog.info(
            "device_auth.hydrating",
            source: .auth,
            payload: ["device_id": deviceId.uuidString]
        )
        Task { @MainActor in
            do {
                let client = clientFactory(self)
                let account = try await client.whoami()
                state = .signedIn(account: account)
                eventLog.info(
                    "device_auth.hydrated",
                    source: .auth,
                    payload: ["email": account.email]
                )
            } catch MaraithonClientError.unauthorized {
                try? keychain.delete()
                state = .signedOut
                eventLog.info("device_auth.hydrate_unauthorized", source: .auth)
            } catch {
                eventLog.warning(
                    "device_auth.hydrate_failed",
                    source: .auth,
                    payload: ["error": String(describing: error)]
                )
                // Transient failure — leave Keychain intact, stay signed-out
                // until the user retries. We don't drop the token on
                // network errors so offline launches don't force re-pair.
            }
        }
    }

    /// The bearer token to attach to outbound requests, or `nil` when
    /// signed out. Reads Keychain on every call so a sign-out from another
    /// surface is honoured immediately.
    var currentToken: String? {
        do {
            return try keychain.get()
        } catch {
            eventLog.warning(
                "device_auth.keychain_read_failed",
                source: .auth,
                payload: ["error": String(describing: error)]
            )
            return nil
        }
    }

    /// Triggered by the Connect button on first-run.
    func beginPairing() {
        state = .connecting
        eventLog.info(
            "device_auth.pair_started",
            source: .auth,
            payload: ["device_id": deviceId.uuidString]
        )
        guard let url = buildPairingURL() else {
            state = .error(message: "Could not build pairing URL")
            eventLog.error("device_auth.pair_url_build_failed", source: .auth)
            return
        }
        urlOpener(url)
        state = .awaitingApproval(deviceId: deviceId)
        eventLog.info(
            "device_auth.awaiting_approval",
            source: .auth,
            payload: ["device_id": deviceId.uuidString, "url": url.absoluteString]
        )
    }

    /// Called by `MaraithonApp.onOpenURL` for `maraithon://device-token/<t>`.
    /// Parses + persists the token, verifies via `whoami`, and transitions
    /// to `.signedIn`. Errors transition to `.error` and the caller's UI
    /// shows the message.
    func handleIncomingURL(_ url: URL) {
        eventLog.info(
            "device_auth.incoming_url",
            source: .auth,
            payload: ["scheme": url.scheme ?? "?", "host": url.host ?? "?"]
        )
        guard let token = DeviceToken(url: url) else {
            eventLog.warning(
                "device_auth.url_ignored",
                source: .auth,
                payload: ["reason": "not a device-token url"]
            )
            return
        }
        Task { @MainActor in
            await self.completePairing(with: token)
        }
    }

    /// Signs the device out: clears the Keychain entry and transitions to
    /// `.signedOut`. Confirmation is the UI's job. The `device_id` is
    /// retained so the user can re-pair the same device without churning
    /// the cloud-side device list.
    func signOut() {
        do {
            try keychain.delete()
        } catch {
            eventLog.warning(
                "device_auth.signout_keychain_failed",
                source: .auth,
                payload: ["error": String(describing: error)]
            )
        }
        state = .signedOut
        eventLog.info("device_auth.signed_out", source: .auth)
    }

    /// Explicit hook for `MaraithonClient` to call when the server returns
    /// 401. Drops the token and forces the user back to the pair flow.
    func tokenRejected() {
        eventLog.warning("device_auth.token_rejected", source: .auth)
        do {
            try keychain.delete()
        } catch {
            eventLog.warning(
                "device_auth.token_reject_delete_failed",
                source: .auth,
                payload: ["error": String(describing: error)]
            )
        }
        state = .error(message: "Sign-in expired. Please connect again.")
    }

    // MARK: - Internals

    private func completePairing(with token: DeviceToken) async {
        do {
            try keychain.set(token.plain)
        } catch {
            eventLog.error(
                "device_auth.keychain_write_failed",
                source: .auth,
                payload: ["error": String(describing: error)]
            )
            state = .error(message: "Could not save credentials")
            return
        }
        do {
            let client = clientFactory(self)
            let account = try await client.whoami()
            state = .signedIn(account: account)
            eventLog.info(
                "device_auth.signed_in",
                source: .auth,
                payload: ["email": account.email, "device_name": account.deviceName]
            )
        } catch MaraithonClientError.unauthorized {
            try? keychain.delete()
            state = .error(message: "Server rejected the pairing token")
            eventLog.error("device_auth.whoami_unauthorized", source: .auth)
        } catch {
            // Token is stored; whoami failed transiently. Surface an
            // actionable error but keep the token for the next retry.
            state = .error(message: "Could not verify account. Reopen Maraithon to finish pairing.")
            eventLog.error(
                "device_auth.whoami_failed",
                source: .auth,
                payload: ["error": String(describing: error)]
            )
        }
    }

    private func buildPairingURL() -> URL? {
        var components = URLComponents(url: authBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/companion/auth"
        components?.queryItems = [
            URLQueryItem(name: "device_id", value: deviceId.uuidString),
            URLQueryItem(name: "device_name", value: deviceName)
        ]
        return components?.url
    }

    private static func loadOrCreateDeviceId(defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: defaultsKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: defaultsKey)
        return fresh
    }

    nonisolated static func defaultDeviceName() -> String {
        ProcessInfo.processInfo.hostName
    }

    /// Reads `MaraithonBaseURL` from the Info.plist so a single config
    /// knob (set in `project.yml`) drives both the HTTP client and the
    /// pair URL. Falls back to the vanity domain.
    nonisolated static func defaultBaseURL() -> URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "MaraithonBaseURL") as? String
        if let configured, let url = URL(string: configured) {
            return url
        }
        return URL(string: "https://maraithon.com")!
    }

    nonisolated static let defaultClientFactory: ClientFactory = { @MainActor auth in
        let tokenProvider: MaraithonClient.TokenProvider = { [weak auth] in
            await MainActor.run { [auth] in auth?.currentToken }
        }
        return MaraithonClient(tokenProvider: tokenProvider)
    }

    nonisolated static let defaultURLOpener: URLOpener = { @MainActor url in
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
