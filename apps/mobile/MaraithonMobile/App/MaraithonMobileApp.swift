import SwiftData
import SwiftUI

@main
@MainActor
struct MaraithonMobileApp: App {
    @State private var sessionStore: SessionStore
    private let modelContainer: ModelContainer

    init() {
        let authProvider = ProductionMagicAuthProvider()
        _sessionStore = State(initialValue: SessionStore(authProvider: authProvider))

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
