import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @State private var didStart = false

    var body: some View {
        Group {
            switch sessionStore.phase {
            case .checking:
                ProgressView(AppLaunchCopy.checkingAccount)
                    .controlSize(.large)
            case .signedOut, .magicLinkSent:
                MagicSigninView()
            case .signedIn:
                AppShellView()
            }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await AppLaunchBootstrap.run(
                sessionStore: sessionStore,
                modelContext: modelContext
            )
        }
        .onOpenURL { url in
            // Navigation deep links (maraithon://today, .../todos, .../chat/<id>)
            // route the UI; everything else is treated as a magic sign-in link.
            // Routing goes through the coordinator's buffer so a link that
            // arrives before the shell mounts (cold launch) isn't dropped.
            if AppNavigation.isNavigationURL(url) {
                PushCoordinator.shared.routeDeepLink(url)
            } else {
                Task {
                    await sessionStore.handleIncomingURL(url)
                }
            }
        }
    }
}

enum AppLaunchCopy {
    static let checkingAccount = "Opening Maraithon"
}
