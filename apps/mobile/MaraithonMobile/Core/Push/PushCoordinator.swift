import Foundation
import os
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when a push notification tap (or nav deep link) should route the UI.
    /// Object is the `maraithon://` destination URL.
    static let maraithonDeepLink = Notification.Name("maraithon.deeplink")
}

/// Owns the push notification lifecycle: permission, APNs token upload,
/// foreground presentation, and tap routing. One instance for the app.
@MainActor
final class PushCoordinator: NSObject {
    static let shared = PushCoordinator()

    /// Supplied by the app at launch so token uploads can authenticate.
    var sessionTokenProvider: (() -> String?)?

    /// Deep link that arrived before the app shell was mounted (cold-launch
    /// push tap, sign-in still restoring). The shell drains it on appear.
    var pendingDeepLink: URL?

    private let apiClient = MobileAPIClient()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MaraithonMobile",
        category: "push"
    )
    private var pendingDeviceToken: String?
    private var uploadedDeviceToken: String?

    /// Routes a navigation deep link. The URL is buffered so a shell mounted
    /// later (cold launch) still routes it; the notification wakes an
    /// already-mounted shell to drain the buffer immediately.
    func routeDeepLink(_ url: URL) {
        pendingDeepLink = url
        NotificationCenter.default.post(name: .maraithonDeepLink, object: url)
    }

    /// Clears the app icon badge; call whenever the app becomes active.
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Call whenever the user is (or becomes) signed in. Asking again after a
    /// prior grant is a no-op; a denial leaves everything quiet.
    func enablePush() async {
        let center = UNUserNotificationCenter.current()

        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        guard granted else { return }

        UIApplication.shared.registerForRemoteNotifications()

        // A token from a previous launch may be waiting on auth that only now exists.
        await uploadPendingTokenIfPossible()
    }

    /// APNs token callback (via AppDelegate). May fire before sign-in completes.
    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingDeviceToken = token

        Task { await uploadPendingTokenIfPossible() }
    }

    func handleRegistrationFailure(_ error: Error) {
        // Simulators and denied capability both land here; nothing to do but log.
        logger.error("Push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Sign-out: remove this device's registration so a signed-out phone stops
    /// receiving another account's notifications.
    func unregisterCurrentDevice() async {
        defer {
            pendingDeviceToken = nil
            uploadedDeviceToken = nil
        }

        guard let token = uploadedDeviceToken ?? pendingDeviceToken,
              let sessionToken = sessionTokenProvider?() else { return }

        try? await apiClient.unregisterPushDevice(sessionToken: sessionToken, deviceToken: token)
    }

    private func uploadPendingTokenIfPossible() async {
        guard let token = pendingDeviceToken,
              token != uploadedDeviceToken,
              let sessionToken = sessionTokenProvider?() else { return }

        do {
            try await apiClient.registerPushDevice(
                sessionToken: sessionToken,
                deviceToken: token,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            )
            uploadedDeviceToken = token
        } catch {
            // Leave the token pending; the next launch or sign-in retries.
            logger.error("Push token upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension PushCoordinator: UNUserNotificationCenterDelegate {
    /// Foreground pushes still show as banners — the app decides relevance by
    /// collapse/thread ids server-side, not by suppressing everything.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        guard let deeplink = userInfo["deeplink"] as? String,
              let url = URL(string: deeplink) else { return }

        await MainActor.run {
            PushCoordinator.shared.routeDeepLink(url)
        }
    }
}
