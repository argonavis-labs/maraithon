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
                ProgressView("Checking session")
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
            Task {
                await sessionStore.handleIncomingURL(url)
            }
        }
    }
}
