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
            if AppNavigation.isNavigationURL(url) {
                NotificationCenter.default.post(name: .maraithonDeepLink, object: url)
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
