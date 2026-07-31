import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Bridges the UIKit push-registration callbacks into `PushCoordinator`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = PushCoordinator.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushCoordinator.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushCoordinator.shared.handleRegistrationFailure(error)
    }
}

@main
@MainActor
struct MaraithonMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var sessionStore: SessionStore
    @State private var modelContainer: ModelContainer

    init() {
        let authProvider = ProductionMagicAuthProvider()
        let store = SessionStore(authProvider: authProvider)
        _sessionStore = State(initialValue: store)

        PushCoordinator.shared.sessionTokenProvider = { [weak store] in
            store?.user?.sessionToken
        }

        // Any API call answered 401 signs the whole app out, not just launch.
        MobileAPIClient.unauthorizedHandler = { [weak store] in
            store?.handleUnauthorized()
        }

        let container: ModelContainer
        do {
            container = try PersistenceController.makeModelContainer()
        } catch {
            // makeModelContainer only throws if even its in-memory fallback fails.
            fatalError("Unable to create SwiftData container: \(error)")
        }
        _modelContainer = State(initialValue: container)

        // Sign-out wipes the previous user's SwiftData rows via this container.
        store.modelContainer = container
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sessionStore)
                .modelContainer(modelContainer)
        }
    }
}
