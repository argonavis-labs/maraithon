import SwiftData

@MainActor
enum AppLaunchBootstrap {
    static func run(sessionStore: SessionStore, modelContext: ModelContext) async {
#if DEBUG
        UITestLaunchSupport.resetStateIfNeeded(modelContext: modelContext)
#endif
        await sessionStore.restore()
#if DEBUG
        await UITestLaunchSupport.consumeMagicLinkIfNeeded(sessionStore: sessionStore)
#endif
    }
}
