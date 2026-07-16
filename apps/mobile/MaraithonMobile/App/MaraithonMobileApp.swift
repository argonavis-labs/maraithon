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
    private let modelContainer: ModelContainer

    init() {
        let authProvider = ProductionMagicAuthProvider()
        let store = SessionStore(authProvider: authProvider)
        _sessionStore = State(initialValue: store)

        PushCoordinator.shared.sessionTokenProvider = { [weak store] in
            store?.user?.sessionToken
        }

        do {
            modelContainer = try PersistenceController.makeModelContainer()
        } catch {
            fatalError("Unable to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sessionStore)
                .modelContainer(modelContainer)
        }
    }
}
